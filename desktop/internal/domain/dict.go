package domain

import (
	"strings"
	"unicode"
)

// Direction 是查词方向。取词与整句翻译共用它做分发。
type Direction string

const (
	// DirectionEnZh 英 → 中（ECDICT）。
	DirectionEnZh Direction = "en-zh"
	// DirectionZhEn 中 → 英（CC-CEDICT）。
	DirectionZhEn Direction = "zh-en"
)

// MaxQueryRune 是单次查词的长度上限。
//
// 正文选区很容易误选整段（在安卓上尤其容易），没有这道闸门时
// 一次误选就会把几十 KB 的文本送进查词链路，日志也会被撑爆。
const MaxQueryRune = 200

// MaxChineseWordRune 是中文最长匹配的搜索窗口。
//
// 汉族词极少超过 8 字（成语多为 4 字），超过 8 字的选区还查不到就
// 判定为句子，交给整句翻译而不是继续在词库里挖。
const MaxChineseWordRune = 8

// DictEntry 是词典库中的一条词条。
//
// 字段与 SQLite 表一一对应，避免在适配器里做无谓的映射层；
// 汉英库只填 Word/Translation/Pinyin/Trad，其余留零值。
type DictEntry struct {
	Word        string
	Phonetic    string
	Translation string
	Pos         string
	Collins     int
	Oxford      bool
	Tags        []string
	BNC         int
	FRQ         int
	// Trad 是繁体写法，仅汉英库有。
	Trad string
	// Pinyin 是拼音，仅汉英库有。
	Pinyin string
}

// DictPackage 是一个词库包的分层与就位状态。
//
// 分层设计的理由是体积：核心 4 MB 内置，全量 46 MB 只能可选下载。
// Builtin 为真的包不可删除——「查个常用词」不能依赖任何网络动作。
type DictPackage struct {
	ID       string
	Name     string
	FileName string
	Size     int64
	Entries  int
	Version  string
	BuiltAt  string
	// Builtin 表示随二进制分发，界面上不显示删除按钮。
	Builtin bool
	// Installed 表示文件已就位。核心库首次解压后即为真。
	Installed bool
}

// DictHit 描述一次命中，以及它是**怎么**命中的。//
// 命中方式必须能传到前端：用户查 perceived 看到 perceive 的释义，
// 不说明「perceived 是 perceive 的过去式」就会以为查错词了。
type DictHit struct {
	Entry DictEntry
	// Query 是归一化后的查询词。
	Query string
	// Key 是词库里实际命中的键。规则还原时可能与 Lemma 不同。
	Key string
	// Lemma 非空表示命中的是变体，Entry.Word 才是原型。
	Lemma string
	// Label 是变体说明，如「过去式」「复数」。
	Label string
	// Rule 为真表示由规则还原命中，而非词形表命中。
	// 规则还原的准确率低于词形表，前端据此弱化这条结果的可信度提示。
	Rule bool
}

// NormalizeQuery 归一化选区文本并判定方向。
//
// 归一化分三段：弯引号还原、空白压缩、去边缘标点。
// 弯引号必须还原——EPUB 里几乎全是 ’“ ”，词典键里全是直引号，
// 不还原的话带所有格的词（reader’s）一条都查不到。
//
// 返回空串表示选区没有可查内容（纯符号、纯空白）。
func NormalizeQuery(text string) (string, Direction) {
	s := curlyQuotes.Replace(text)
	s = strings.Join(strings.Fields(s), " ")
	s = strings.TrimFunc(s, isEdgePunct)
	if s == "" {
		return "", ""
	}
	if n := len([]rune(s)); n > MaxQueryRune {
		// 超长不报错，截断后照常查：误选整段时截断查法比报错有用。
		r := []rune(s)
		s = strings.TrimFunc(string(r[:MaxQueryRune]), isEdgePunct)
	}
	if HasCJK(s) {
		return s, DirectionZhEn
	}
	return strings.ToLower(s), DirectionEnZh
}

// HasCJK 报告字符串里是否含汉字。
//
// 只认汉字本身，不认全角标点：`——` 这类纯标点选区应当被判成
// 「无可查内容」而不是中文词。
func HasCJK(s string) bool {
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			return true
		}
	}
	return false
}

// CountCJK 返回汉字个数，用于判断「是否整句」。
func CountCJK(s string) int {
	n := 0
	for _, r := range s {
		if unicode.Is(unicode.Han, r) {
			n++
		}
	}
	return n
}

// QueryWords 返回英文词数，用于判断「是否整句」。
func QueryWords(s string) int {
	return len(strings.Fields(s))
}

var curlyQuotes = strings.NewReplacer(
	"\u2018", "'", "\u2019", "'", // ‘ ’
	"\u201c", "\"", "\u201d", "\"", // “ ”
	"\u00a0", " ", // 不换行空格
	"\u2010", "-", "\u2011", "-", "\u2012", "-", "\u2013", "-", // 各种连字符
)

// isEdgePunct 判定是否为应从选区边缘剥掉的字符。
//
// 只处理边缘，不动词内部的连字符与撇号：half-an-hour、reader's
// 剥掉就查不到了。撇号例外——它在句首句尾（'tis、dogs'）时确实是标点。
func isEdgePunct(r rune) bool {
	if unicode.IsSpace(r) {
		return true
	}
	if unicode.IsPunct(r) {
		return true
	}
	if unicode.IsSymbol(r) {
		return true
	}
	// 中文标点落在 Punct/Symbol 之外的情况（如 〇 之外的装饰符）这里不追。
	return false
}

// SplitTags 把 `cet4 cet6 ielts` 拆成切片。
//
// ECDICT 的 tag 字段是空格分隔的考试标签，直接当字符串回给前端
// 会让前端各自实现拆分规则，所以在这里统一拆一次。
func SplitTags(s string) []string {
	if s == "" {
		return nil
	}
	out := strings.Fields(s)
	if len(out) == 0 {
		return nil
	}
	return out
}

// EnglishCandidates 返回英文词的**规则还原**候选原型，按可信度从高到低。
//
// 这只作为词形表（ECDICT 的 exchange 字段，56409 条）的最后兜底。
// 实测规则还原的贡献不到 1% 词次，但它能捞回词形表漏收的新造词与专名变形，
// 成本是几十次 map 查询，值得留。
//
// 顺序刻意按「最不可能误判」排：所有格 > 复数 > 过去式 > 进行式 > 比较级 > 副词。
// 先命中的先返回，避免 -ing 规则把一个本来就是原形的词（如 during）改坏。
func EnglishCandidates(word string) []string {
	var out []string
	seen := make(map[string]bool, 12)
	add := func(s string) {
		if s == "" || s == word || seen[s] {
			return
		}
		seen[s] = true
		out = append(out, s)
	}

	// 所有格与缩写：reader's → reader，dogs' → dogs，don't → do
	if strings.HasSuffix(word, "'s") {
		add(word[:len(word)-2])
	}
	if strings.HasSuffix(word, "'") {
		add(word[:len(word)-1])
	}
	if strings.HasSuffix(word, "n't") && len(word) > 3 {
		add(word[:len(word)-3])
	}
	if i := strings.IndexByte(word, '\''); i > 0 {
		add(word[:i])
	}

	// 复数与三单
	if strings.HasSuffix(word, "ies") && len(word) > 3 {
		add(word[:len(word)-3] + "y") // studies → study
	}
	if strings.HasSuffix(word, "ves") && len(word) > 3 {
		add(word[:len(word)-3] + "f") // wolves → wolf
		add(word[:len(word)-3] + "fe")
	}
	if strings.HasSuffix(word, "es") && len(word) > 2 {
		add(word[:len(word)-2]) // boxes → box
		add(word[:len(word)-1]) // names → name
	}
	if strings.HasSuffix(word, "s") && !strings.HasSuffix(word, "ss") && len(word) > 1 {
		add(word[:len(word)-1])
	}

	// 过去式与过去分词
	if strings.HasSuffix(word, "ied") && len(word) > 3 {
		add(word[:len(word)-3] + "y") // carried → carry
	}
	if strings.HasSuffix(word, "ed") && len(word) > 2 {
		base := word[:len(word)-2]
		add(base)           // walked → walk
		add(base + "e")     // loved → love
		add(undouble(base)) // stopped → stop
	}

	// 进行式与现在分词
	if strings.HasSuffix(word, "ing") && len(word) > 3 {
		base := word[:len(word)-3]
		add(base)           // walking → walk
		add(base + "e")     // making → make
		add(undouble(base)) // running → run
	}

	// 比较级与最高级
	for _, suf := range []string{"est", "er"} {
		if strings.HasSuffix(word, suf) && len(word) > len(suf)+1 {
			base := word[:len(word)-len(suf)]
			add(base)
			add(base + "e")
			add(undouble(base))
			if strings.HasSuffix(base, "i") {
				add(base[:len(base)-1] + "y")
			}
		}
	}

	// 副词
	if strings.HasSuffix(word, "ly") && len(word) > 3 {
		base := word[:len(word)-2]
		add(base)       // quickly → quick
		add(base + "e") // simply → simple
	}

	return out
}

// undouble 去掉词尾重复的辅音（stopp → stop、runn → run）。
//
// 只对辅音生效：`ee`（see → s）与 `ll`（fall → fal）都不是重复辅音变体，
// 去掉反而错。
func undouble(s string) string {
	if len(s) < 2 {
		return ""
	}
	n := len(s)
	if s[n-1] != s[n-2] {
		return ""
	}
	c := s[n-1]
	if strings.ContainsRune("aeiou", rune(c)) {
		return ""
	}
	return s[:n-1]
}

// ChineseSegments 生成中文最长匹配的候选子串，按长度从长到短。
//
// 只覆盖长度 2..MaxChineseWordRune 的窗口，单字由调用方兜底：
// 单字命中率极高但意义极低（`的`、`了`），必须排在最后且单独标注。
func ChineseSegments(text string) []string {
	r := []rune(text)
	n := len(r)
	if n <= 1 {
		return nil
	}
	maxLen := n
	if maxLen > MaxChineseWordRune {
		maxLen = MaxChineseWordRune
	}
	out := make([]string, 0, maxLen*n)
	for l := maxLen; l >= 2; l-- {
		for i := 0; i+l <= n; i++ {
			out = append(out, string(r[i:i+l]))
		}
	}
	return out
}

// formTypeLabels 把 ECDICT 的关系类型码翻成中文。
//
// 类型码来自 exchange 字段：p/d/i/3/s/r/t。
var formTypeLabels = map[string]string{
	"p": "过去式",
	"d": "过去分词",
	"i": "现在分词",
	"3": "第三人称单数",
	"s": "复数",
	"r": "比较级",
	"t": "最高级",
}

// FormLabel 生成「这是 xx 的什么形式」里的「什么形式」。
//
// 优先用词库记录的关系类型：只有它能把 had 说成「过去式/过去分词」，
// 靠后缀猜则会因为 had 与 have 毫无共同前缀而退化成「变形」——
// 而 had 恰恰是阅读里最高频的几个词之一。
//
// 词库没记关系（词形表命中但没有类型码）时退回后缀启发式，
// 再不行才说「变形」，不猜具体时态：猜错比不说更糟。
func FormLabel(types, query, lemma string) string {
	var parts []string
	for _, code := range strings.Split(types, ",") {
		if label, ok := formTypeLabels[code]; ok {
			parts = append(parts, label)
		}
	}
	if len(parts) > 0 {
		return strings.Join(parts, "/")
	}
	return suffixFormLabel(query, lemma)
}

// suffixFormLabel 按后缀猜变形类型，作为没有类型码时的兜底。
func suffixFormLabel(query, lemma string) string {
	if !strings.HasPrefix(query, strings.TrimRight(lemma, "e")) &&
		!strings.HasPrefix(query, lemma) {
		return "变形"
	}
	switch {
	case strings.HasSuffix(query, "ing"):
		return "现在分词/进行式"
	case strings.HasSuffix(query, "ied"), strings.HasSuffix(query, "ed"):
		return "过去式/过去分词"
	case strings.HasSuffix(query, "ier"), strings.HasSuffix(query, "er"):
		return "比较级"
	case strings.HasSuffix(query, "iest"), strings.HasSuffix(query, "est"):
		return "最高级"
	case strings.HasSuffix(query, "ies"), strings.HasSuffix(query, "es"), strings.HasSuffix(query, "s"):
		return "复数/第三人称单数"
	case strings.HasSuffix(query, "ly"):
		return "副词形式"
	}
	return "变形"
}

// ChineseSingles 返回去重后的单字，供单字兜底使用。
func ChineseSingles(text string) []string {
	seen := make(map[rune]bool, len(text))
	out := make([]string, 0, len(text))
	for _, r := range text {
		if !unicode.Is(unicode.Han, r) || seen[r] {
			continue
		}
		seen[r] = true
		out = append(out, string(r))
	}
	return out
}
