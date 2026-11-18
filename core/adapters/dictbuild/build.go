// Package dictbuild 把上游词典数据转换成应用使用的 SQLite 词库。
//
// 两条链路共用同一份实现：
//   - 离线构建（cmd/dictbuild）：把 ecdict.csv 转成随二进制分发的核心库；
//   - 运行时安装（M4）：用户下载的上游源文件在本地转换后落位。
//
// 共用是刻意的：一旦两边各写一份，schema 与词形规则会悄悄漂移，
// 表现为「内置库查得到、下载的库查不到」这类难查的问题。
package dictbuild

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	_ "modernc.org/sqlite"
)

// Progress 汇报转换进度。done / total 都是**字节数**：
// 行数总量事先不知道，按已读字节算百分比才准确。
//
// total 为 0 表示未知，调用方应显示为不确定进度。
type Progress func(done, total int64)

// TierLimit 把档位名换成词频阈值：词频 <= limit 的词条进库。
func TierLimit(tier string) (int, error) {
	switch tier {
	case "core":
		return 30000, nil
	case "standard":
		return 60000, nil
	case "full":
		return 1 << 30, nil
	default:
		return 0, fmt.Errorf("未知档位 %q（可用：core / standard / full）", tier)
	}
}

// ECDICT 把 ECDICT 的 ecdict.csv 转换成英文词库。
//
// 关键规则（踩过坑才写下的，见设计方案 §0 结论 1）：
// 主体词条按词频裁剪，**词形表一律全量保留**。
// ECDICT 把 had / were / been 这类自动生成的变化形式也收成了独立词条，
// 但它们没有 bnc/frq 标注；如果词形表也跟着裁剪，这批最常用的词会整批消失，
// 实测损失 3.74% 的词次。
func ECDICT(ctx context.Context, csvPath, outPath, tier string, onProgress Progress) (int, error) {
	freqLimit, err := TierLimit(tier)
	if err != nil {
		return 0, err
	}
	f, err := os.Open(csvPath)
	if err != nil {
		return 0, fmt.Errorf("打开 CSV: %w", err)
	}
	defer f.Close() //nolint:errcheck

	info, err := f.Stat()
	if err != nil {
		return 0, err
	}
	counter := &countReader{r: f}
	r := csv.NewReader(counter)
	// ECDICT 的 detail 字段里有极长的 JSON 与换行，必须放开字段长度限制。
	r.FieldsPerRecord = -1
	r.LazyQuotes = true
	r.ReuseRecord = false

	header, err := r.Read()
	if err != nil {
		return 0, fmt.Errorf("读取表头: %w", err)
	}
	col := make(map[string]int, len(header))
	for i, name := range header {
		col[strings.TrimSpace(name)] = i
	}
	for _, need := range []string{"word", "translation", "exchange"} {
		if _, ok := col[need]; !ok {
			return 0, fmt.Errorf("CSV 缺少必需列 %q", need)
		}
	}
	get := func(rec []string, name string) string {
		i, ok := col[name]
		if !ok || i >= len(rec) {
			return ""
		}
		return strings.TrimSpace(rec[i])
	}
	getInt := func(rec []string, name string) int {
		s := get(rec, name)
		if s == "" {
			return 0
		}
		n, err := strconv.Atoi(s)
		if err != nil {
			return 0
		}
		return n
	}

	db, err := createDB(outPath)
	if err != nil {
		return 0, err
	}
	defer db.Close() //nolint:errcheck

	const schema = `
CREATE TABLE word(
  w TEXT PRIMARY KEY,   -- 小写规范词
  ph TEXT,              -- 音标
  tr TEXT,              -- 中文释义（换行分隔多义）
  pos TEXT,             -- 词性
  collins INT,          -- 柯林斯星级
  oxford INT,           -- 是否牛津 3000
  tag TEXT,             -- 考试标签（空格分隔）
  bnc INT,              -- BNC 词频排名
  frq INT               -- 当代语料词频排名
) WITHOUT ROWID;
CREATE TABLE form(
  v TEXT PRIMARY KEY,   -- 变体（过去式/复数…）
  l TEXT,               -- 原型
  t TEXT                -- 关系类型，如 p,d（过去式+过去分词）
) WITHOUT ROWID;
`
	if _, err := db.Exec(schema); err != nil {
		return 0, fmt.Errorf("建表: %w", err)
	}

	tx, err := db.Begin()
	if err != nil {
		return 0, err
	}
	wordStmt, err := tx.Prepare("INSERT OR IGNORE INTO word VALUES(?,?,?,?,?,?,?,?,?)")
	if err != nil {
		return 0, err
	}

	// 词形表先在内存里合并再写库。
	//
	// 必须合并而不是边读边插：`had` 既是 have 的过去式（p）又是过去分词（d），
	// 在 CSV 里就是两条记录，直接 INSERT OR IGNORE 会让它只剩「过去式」，
	// 而对 had 来说这两个身份同时成立。合并后存成 `p,d`。
	forms := make(map[string]*formRec, 96_000)
	recordForm := func(surface, lemma, typ string) {
		if surface == "" || lemma == "" || surface == lemma {
			return
		}
		f := forms[surface]
		if f == nil {
			f = &formRec{lemma: lemma, types: map[string]bool{}}
			forms[surface] = f
		}
		if typ != "" {
			f.types[typ] = true
		}
	}

	var kept, total int
	for {
		if total%20000 == 0 {
			if err := ctx.Err(); err != nil {
				return 0, err
			}
			if onProgress != nil {
				onProgress(counter.n, info.Size())
			}
		}
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			return 0, fmt.Errorf("第 %d 行: %w", total+2, err)
		}
		total++

		word := strings.ToLower(get(rec, "word"))
		if word == "" {
			continue
		}

		exchange := get(rec, "exchange")
		// 反向关系：本行是某个原型的变形（`0:lemma`）。
		// 这条只给出原型，关系类型由原型那一行的 p:/d:/i: 决定。
		if lemma := lemmaOf(exchange); lemma != "" && lemma != word {
			recordForm(word, lemma, "")
		}
		// 正向关系：本行是原型，列出自己的各个变形。
		for typ, surface := range derivedForms(exchange) {
			recordForm(surface, word, typ)
		}

		// 主体表：没有中文释义的词条对阅读者没有意义（形如专名的空壳）。
		tr := get(rec, "translation")
		if tr == "" {
			continue
		}
		bnc := getInt(rec, "bnc")
		frq := getInt(rec, "frq")
		collins := getInt(rec, "collins")
		oxford := getInt(rec, "oxford")
		tag := get(rec, "tag")
		if !keepInTier(bnc, frq, collins, oxford, tag, freqLimit) {
			continue
		}
		if _, err := wordStmt.Exec(word, get(rec, "phonetic"), tr, get(rec, "pos"),
			collins, oxford, tag, bnc, frq); err != nil {
			return 0, err
		}
		kept++
	}

	// 词形表全量写入，**不做任何裁剪**：体积只有 1 MB 级，
	// 换的是「had/were/been 查得到」（设计方案 §0 结论 1）。
	formStmt, err := tx.Prepare("INSERT OR IGNORE INTO form VALUES(?,?,?)")
	if err != nil {
		return 0, err
	}
	for surface, f := range forms {
		if f.lemma == "" {
			continue
		}
		if _, err := formStmt.Exec(surface, f.lemma, f.typeString()); err != nil {
			return 0, err
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	// VACUUM 必须在事务外执行，否则体积差出 20% 以上。
	if _, err := db.Exec("VACUUM"); err != nil {
		return 0, fmt.Errorf("VACUUM: %w", err)
	}
	if onProgress != nil {
		onProgress(info.Size(), info.Size())
	}
	return kept, nil
}

// cedictLine 匹配 CC-CEDICT 的一行：
//
//	繁體 简体 [pin1 yin1] /释义 一/释义 二/
var cedictLine = regexp.MustCompile(`^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+/(.*)/\s*$`)

// CEDICT 把 CC-CEDICT 的 cedict_ts.u8 转换成汉英词库。
//
// 与英文库不同，汉英库是**全量写入**：CC-CEDICT 只有 12 万条、13 MB，
// 没有可裁的"低频词尾"，裁掉就只是让用户查不到。
func CEDICT(ctx context.Context, u8Path, outPath string, onProgress Progress) (int, error) {
	f, err := os.Open(u8Path)
	if err != nil {
		return 0, fmt.Errorf("打开 CC-CEDICT: %w", err)
	}
	defer f.Close() //nolint:errcheck

	info, err := f.Stat()
	if err != nil {
		return 0, err
	}

	db, err := createDB(outPath)
	if err != nil {
		return 0, err
	}
	defer db.Close() //nolint:errcheck

	if _, err := db.Exec(`CREATE TABLE zh(z TEXT, py TEXT, en TEXT, trad TEXT)`); err != nil {
		return 0, fmt.Errorf("建表: %w", err)
	}

	tx, err := db.Begin()
	if err != nil {
		return 0, err
	}
	stmt, err := tx.Prepare("INSERT INTO zh VALUES(?,?,?,?)")
	if err != nil {
		return 0, err
	}

	sc := bufio.NewScanner(&countReader{r: f, onRead: func(n int64) {
		if onProgress != nil && n%(1<<20) < 64*1024 { // 每读约 1 MB 报一次
			onProgress(n, info.Size())
		}
	}})
	sc.Buffer(make([]byte, 64*1024), 1<<20)

	var n, lines int
	for sc.Scan() {
		lines++
		if lines%20000 == 0 {
			if err := ctx.Err(); err != nil {
				return 0, err
			}
		}
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		m := cedictLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		trad, simp, py, defs := m[1], m[2], m[3], m[4]
		parts := strings.Split(defs, "/")
		kept := parts[:0]
		for _, d := range parts {
			if d = strings.TrimSpace(d); d != "" {
				kept = append(kept, d)
			}
		}
		if len(kept) == 0 {
			continue
		}
		if _, err := stmt.Exec(simp, py, strings.Join(kept, "; "), trad); err != nil {
			return 0, err
		}
		n++
	}
	if err := sc.Err(); err != nil {
		return 0, fmt.Errorf("读取 CC-CEDICT: %w", err)
	}
	if n == 0 {
		return 0, fmt.Errorf("文件里没有解析出任何词条，可能不是 CC-CEDICT 格式")
	}

	// 索引在所有插入之后建：边插边维护索引会让构建慢一个数量级。
	if _, err := tx.Exec("CREATE INDEX idx_z ON zh(z)"); err != nil {
		return 0, err
	}
	if _, err := tx.Exec("CREATE INDEX idx_t ON zh(trad)"); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	if _, err := db.Exec("VACUUM"); err != nil {
		return 0, fmt.Errorf("VACUUM: %w", err)
	}
	if onProgress != nil {
		onProgress(info.Size(), info.Size())
	}
	return n, nil
}

// createDB 建库并关掉构建期用不上的开销。
//
// 这是「一次性写入产物」，崩溃重跑即可，不需要为 77 万行付 WAL 与 fsync 的代价。
func createDB(outPath string) (*sql.DB, error) {
	if dir := filepath.Dir(outPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	_ = os.Remove(outPath)
	db, err := sql.Open("sqlite", outPath)
	if err != nil {
		return nil, fmt.Errorf("创建 %q: %w", outPath, err)
	}
	for _, p := range []string{
		"PRAGMA journal_mode=OFF",
		"PRAGMA synchronous=OFF",
		"PRAGMA page_size=4096",
		"PRAGMA cache_size=-64000",
	} {
		if _, err := db.Exec(p); err != nil {
			db.Close() //nolint:errcheck
			return nil, fmt.Errorf("%s: %w", p, err)
		}
	}
	return db, nil
}

// countReader 统计已读字节，用于按体积汇报进度。
type countReader struct {
	r      io.Reader
	n      int64
	onRead func(n int64)
}

func (c *countReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	if c.onRead != nil && n > 0 {
		c.onRead(c.n)
	}
	return n, err
}

// keepInTier 判定词条是否进当前档位。
//
// 除了词频，还保留三档"必留"信号：柯林斯星级、牛津 3000、考试标签。
// 原因是词频排名只覆盖到 6 万左右，`serendipity` 这类低频但常出现在
// 文学作品里的词会被裁掉，而这正是阅读场景最需要的词。
func keepInTier(bnc, frq, collins, oxford int, tag string, limit int) bool {
	if collins > 0 || oxford > 0 || tag != "" {
		return true
	}
	if bnc > 0 && bnc <= limit {
		return true
	}
	if frq > 0 && frq <= limit {
		return true
	}
	return false
}

// lemmaOf 从 exchange 字段取原型。
//
// exchange 形如 `p:perceived/d:perceived/i:perceiving/3:perceives`，
// 其中 `0:<lemma>` 才是原型；没有 0 标签说明这个词本身就是原型。
func lemmaOf(exchange string) string {
	if exchange == "" {
		return ""
	}
	for _, item := range strings.Split(exchange, "/") {
		if strings.HasPrefix(item, "0:") {
			return strings.ToLower(strings.TrimSpace(item[2:]))
		}
	}
	return ""
}

// formRec 是词形表中的一个变体。
//
// types 是关系类型的集合而不是单值：`had` 同时是 have 的过去式（p）与
// 过去分词（d），在两个维度上都是事实，只留一个会说错话。
type formRec struct {
	lemma string
	types map[string]bool
}

// typeString 按固定顺序输出类型码，如 `p,d`。
//
// 固定顺序是为了产物可复现：map 遍历顺序随机，不排序会让每次构建的
// sha256 都不一样，manifest 校验会永远对不上。
func (f *formRec) typeString() string {
	if len(f.types) == 0 {
		return ""
	}
	var parts []string
	for _, c := range []string{"p", "d", "i", "3", "s", "r", "t"} {
		if f.types[c] {
			parts = append(parts, c)
		}
	}
	return strings.Join(parts, ",")
}

// supportedFormTypes 是 ECDICT exchange 里我们用得上的关系标签。
//
//	p = past（过去式）      d = past participle（过去分词）
//	i = -ing 形式          3 = 第三人称单数
//	s = 复数               r = 比较级        t = 最高级
//
// 0 是「本词是某词的原型」的反向声明，单独由 lemmaOf 处理。
var supportedFormTypes = map[string]bool{
	"p": true, "d": true, "i": true, "3": true, "s": true, "r": true, "t": true,
}

// derivedForms 解析出一行里声明**自己的**各个变形。
//
// 返回 类型码 → 变形写法。没有 exchange 或全是 0: 时返回空。
func derivedForms(exchange string) map[string]string {
	if exchange == "" {
		return nil
	}
	out := make(map[string]string, 6)
	for _, item := range strings.Split(exchange, "/") {
		i := strings.IndexByte(item, ':')
		if i <= 0 {
			continue
		}
		typ := item[:i]
		if !supportedFormTypes[typ] {
			continue
		}
		surface := strings.ToLower(strings.TrimSpace(item[i+1:]))
		if surface == "" {
			continue
		}
		out[typ] = surface
	}
	return out
}
