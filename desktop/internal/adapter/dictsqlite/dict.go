// Package dictsqlite 用 modernc.org/sqlite 以**只读**方式打开词典库。
//
// 与 internal/adapter/persistence/sqlite 分开是刻意的：
// 业务库（legado.db）要迁移、要事务、要单写连接；词典库是外部构建产物，
// 结构固定、永不写入、坏了直接重装。把两者混在一个包里，迁移逻辑会
// 不必要地作用到词库文件上（见设计方案 §4.3「词典库不进主库迁移」）。
package dictsqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	// 注册 "sqlite" 驱动（纯 Go，无 cgo）。
	_ "modernc.org/sqlite"

	"github.com/legado/desktop/internal/domain"
)

// Repo 是只读词典库的仓储实现。
type Repo struct {
	db   *sql.DB
	path string
}

// OpenReadOnly 以只读模式打开词库文件。
//
// 用 mode=ro 而不是打开后不加写：词库被意外写入（比如某天有人图方便
// 加个「生词本」写到同一个文件）后果是用户升级时词库校验不过，
// 排查成本远高于现在加一个参数。
//
// immutable=1 告诉 SQLite 文件不会变，跳过锁与变更检测——只读库上
// 这能省掉每次查询的 stat 与共享锁开销。
func OpenReadOnly(path string) (*Repo, error) {
	dsn := "file:" + filepath.ToSlash(path) + "?mode=ro&immutable=1"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开词库 %q 失败: %w", path, err)
	}
	// 查词是单次点查，几十微秒级；多连接只会增加句柄开销。
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)

	// sql.Open 是惰性的，必须真查一次才能发现"文件损坏/不是数据库"。
	if err := db.PingContext(context.Background()); err != nil {
		db.Close() //nolint:errcheck
		return nil, fmt.Errorf("词库 %q 无法读取: %w", path, err)
	}
	return &Repo{db: db, path: path}, nil
}

// Path 返回词库文件路径，便于日志与错误信息定位。
func (r *Repo) Path() string { return r.path }

// Close 释放只读连接。
func (r *Repo) Close() error {
	if r == nil || r.db == nil {
		return nil
	}
	return r.db.Close()
}

// Check 执行 PRAGMA quick_check，用于安装后与启动时的完整性校验。
//
// 只校验结构不校验内容，比 integrity_check 快两个数量级，
// 足以拦住"文件截断/不是 SQLite"这类真实故障。
func (r *Repo) Check(ctx context.Context) error {
	var result string
	if err := r.db.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if !strings.EqualFold(result, "ok") {
		return fmt.Errorf("词库自检未通过: %s", result)
	}
	return nil
}

const wordCols = "w, ph, tr, pos, collins, oxford, tag, bnc, frq"

// LookupWord 精确查主表。
func (r *Repo) LookupWord(ctx context.Context, word string) (*domain.DictEntry, error) {
	row := r.db.QueryRowContext(ctx,
		"SELECT "+wordCols+" FROM word WHERE w = ? LIMIT 1", word)
	e, err := scanWord(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, domain.ErrNotFound
		}
		return nil, fmt.Errorf("查词 %q 失败: %w", word, err)
	}
	return e, nil
}

// LookupForm 在词形表里把变体还原成原型。
//
// 第二个返回值是关系类型码（`p` 过去式、`d` 过去分词…），
// 由 cmd/dictbuild 从 ECDICT 的 exchange 字段解析出来。
func (r *Repo) LookupForm(ctx context.Context, variant string) (string, string, bool, error) {
	var lemma, types string
	err := r.db.QueryRowContext(ctx,
		"SELECT l, t FROM form WHERE v = ? LIMIT 1", variant).Scan(&lemma, &types)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", "", false, nil
		}
		return "", "", false, fmt.Errorf("查词形 %q 失败: %w", variant, err)
	}
	return lemma, types, true, nil
}

// LookupZh 查汉英库。
//
// 同一简体词可能对应多条（不同繁体/不同义项），全部返回，
// 由上层按拼音去重。
func (r *Repo) LookupZh(ctx context.Context, word string) ([]domain.DictEntry, error) {
	rows, err := r.db.QueryContext(ctx,
		"SELECT z, py, en, trad FROM zh WHERE z = ?", word)
	if err != nil {
		return nil, fmt.Errorf("查中文词 %q 失败: %w", word, err)
	}
	defer rows.Close() //nolint:errcheck

	var out []domain.DictEntry
	for rows.Next() {
		var (
			z, py, en, trad string
		)
		if err := rows.Scan(&z, &py, &en, &trad); err != nil {
			return nil, err
		}
		out = append(out, domain.DictEntry{
			Word:        z,
			Translation: en,
			Pinyin:      py,
			Trad:        trad,
		})
	}
	return out, rows.Err()
}

// PrefixWords 取以 prefix 开头的前 limit 个词。
//
// 用键区间而不是 LIKE：word 表是 WITHOUT ROWID 且以 w 为主键，
// 区间查询能走 B 树顺序扫描，`LIKE 'abc%'` 则要取决于
// case_sensitive_like 这个连接级 PRAGMA，不可靠。
func (r *Repo) PrefixWords(ctx context.Context, prefix string, limit int) ([]string, error) {
	if prefix == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 5
	}
	var (
		rows *sql.Rows
		err  error
	)
	if hi := upperBound(prefix); hi != "" {
		rows, err = r.db.QueryContext(ctx,
			"SELECT w FROM word WHERE w >= ? AND w < ? ORDER BY w LIMIT ?", prefix, hi, limit)
	} else {
		rows, err = r.db.QueryContext(ctx,
			"SELECT w FROM word WHERE w >= ? ORDER BY w LIMIT ?", prefix, limit)
	}
	if err != nil {
		return nil, fmt.Errorf("前缀查词 %q 失败: %w", prefix, err)
	}
	defer rows.Close() //nolint:errcheck

	out := make([]string, 0, limit)
	for rows.Next() {
		var w string
		if err := rows.Scan(&w); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

// upperBound 返回 prefix 的字典序上界（不含），用于区间查询。
//
// 逐字节加一：`abz` → `ab{`。末字节为 0xFF 时向前进位，
// 全 0xFF 时返回空串表示没有上界（此时退化为只给下界）。
//
// 按字节而非按 rune 处理是安全的：返回值只当比较串用，
// 即使切在 UTF-8 中间也不影响 SQLite 的 BINARY 比较结果。
func upperBound(prefix string) string {
	b := []byte(prefix)
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] < 0xFF {
			b[i]++
			return string(b[:i+1])
		}
	}
	return ""
}

// rowScanner 抽象 *sql.Row 与 *sql.Rows 的 Scan，便于复用列解析。
type rowScanner interface {
	Scan(dest ...any) error
}

func scanWord(s rowScanner) (*domain.DictEntry, error) {
	var (
		e       domain.DictEntry
		tags    string
		oxford  int
		collins int
	)
	if err := s.Scan(&e.Word, &e.Phonetic, &e.Translation, &e.Pos,
		&collins, &oxford, &tags, &e.BNC, &e.FRQ); err != nil {
		return nil, err
	}
	e.Collins = collins
	e.Oxford = oxford != 0
	e.Tags = domain.SplitTags(tags)
	return &e, nil
}
