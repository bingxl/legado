// Package bookmark 是书签与阅读记录域：书签增删查、阅读记录流水、进度同步。
//
// 与 Shelf（阅读进度当前值）的分工：
// 本模块记录**流水与位置标记**，Shelf 负责「这本书现在读到哪」。
// 两边都写 books 表会互相覆盖，因此这里不提供 SaveProgress 类方法。
package bookmark

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// Module 实现 kernel.Module。
type Module struct {
	db  *sqlite.DB
	bm  *BookmarkService
	rec *RecordService
}

// New 构造模块。进度读取器缺省为 nil（书签章节号按调用方传入处理）。
func New(db *sqlite.DB) *Module { return NewWithProgress(db, nil) }

// NewWithProgress 构造模块并注入进度读取器。
//
// 装配层若已拿到 BookshelfService，可写一个适配器传入；
// 未注入也能工作，只是「当前位置」类调用会退化为第 0 章。
func NewWithProgress(db *sqlite.DB, p ProgressReader) *Module {
	return &Module{
		db:  db,
		bm:  NewBookmarkService(db, p),
		rec: NewRecordService(db, p),
	}
}

// Name 返回模块名。
func (m *Module) Name() string { return "bookmark" }

// DependsOn 声明依赖模块。
func (m *Module) DependsOn() []string { return nil }

// Migrate 建表（幂等）。
func (m *Module) Migrate(ctx context.Context) error {
	return m.db.EnsureSchema(ctx, `CREATE TABLE IF NOT EXISTS bookmark (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		book_id INTEGER NOT NULL,
		chapter_index INTEGER NOT NULL DEFAULT 0,
		chapter_title TEXT NOT NULL DEFAULT '',
		chapter_pos INTEGER NOT NULL DEFAULT 0,
		content TEXT NOT NULL DEFAULT '',
		note TEXT NOT NULL DEFAULT '',
		created_at INTEGER NOT NULL DEFAULT (unixepoch())
	);
	CREATE INDEX IF NOT EXISTS idx_bookmark_book ON bookmark(book_id, chapter_index);
	CREATE TABLE IF NOT EXISTS read_record (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		book_id INTEGER NOT NULL,
		book_name TEXT NOT NULL DEFAULT '',
		chapter_index INTEGER NOT NULL DEFAULT 0,
		chapter_title TEXT NOT NULL DEFAULT '',
		read_at INTEGER NOT NULL DEFAULT (unixepoch())
	);
	CREATE INDEX IF NOT EXISTS idx_read_record_time ON read_record(read_at DESC);
	-- Append 的「同书同日同章」查重按 book_id+chapter_index 过滤，
	-- 每开一章都会跑一次；只靠 read_at 索引会退化成全表扫描。
	CREATE INDEX IF NOT EXISTS idx_read_record_book ON read_record(book_id, chapter_index, read_at);`)
}

// Register 把本域能力交给内核。
//
// 每个方法都用 kernel.Sig 声明参数名与类型：手写 handler 的参数活在闭包里，
// 反射拿不到，不声明的话 `legado schema` 会导出 arity=0，Dart 侧就无法校验参数个数。
// Sig 的顺序必须与 handler 里按位置解码的顺序一致。
func (m *Module) Register(r *kernel.Registry) {
	// ---- 书签 ----
	r.Method("Bookmark.Add", func(ctx context.Context, args []json.RawMessage) (any, error) {
		bookID, err := argID(args, 0, "书籍 ID")
		if err != nil {
			return nil, err
		}
		chapterIndex, err := argInt(args, 1)
		if err != nil {
			return nil, err
		}
		chapterTitle, err := argString(args, 2)
		if err != nil {
			return nil, err
		}
		chapterPos, err := argInt(args, 3)
		if err != nil {
			return nil, err
		}
		content, err := argString(args, 4)
		if err != nil {
			return nil, err
		}
		note, err := argString(args, 5)
		if err != nil {
			return nil, err
		}
		return m.bm.Add(ctx, bookID, chapterIndex, chapterTitle, chapterPos, content, note)
	}, kernel.Sig(
		"bookId int64",
		"chapterIndex int",
		"chapterTitle string",
		"chapterPos int",
		"content string",
		"note string",
	), kernel.Doc("新增书签；chapterIndex<0 表示当前位置（由注入的进度读取器解析）"))

	r.Method("Bookmark.List", func(ctx context.Context, args []json.RawMessage) (any, error) {
		// bookId=0 有语义（全部），所以这里不能用「必填」版本解码。
		bookID, err := argInt64(args, 0)
		if err != nil {
			return nil, err
		}
		limit, err := argInt(args, 1)
		if err != nil {
			return nil, err
		}
		return m.bm.List(ctx, bookID, limit)
	}, kernel.Sig("bookId int64", "limit int"),
		kernel.Doc("列出书签；bookId=0 表示全部，按创建时间倒序"))

	r.Method("Bookmark.Remove", func(ctx context.Context, args []json.RawMessage) (any, error) {
		id, err := argID(args, 0, "书签 ID")
		if err != nil {
			return nil, err
		}
		return nil, m.bm.Remove(ctx, id)
	}, kernel.Sig("id int64"), kernel.Doc("删除书签"))

	r.Method("Bookmark.UpdateNote", func(ctx context.Context, args []json.RawMessage) (any, error) {
		id, err := argID(args, 0, "书签 ID")
		if err != nil {
			return nil, err
		}
		note, err := argString(args, 1)
		if err != nil {
			return nil, err
		}
		return nil, m.bm.UpdateNote(ctx, id, note)
	}, kernel.Sig("id int64", "note string"), kernel.Doc("修改书签备注"))

	r.Method("Bookmark.Count", func(ctx context.Context, args []json.RawMessage) (any, error) {
		bookID, err := argID(args, 0, "书籍 ID")
		if err != nil {
			return nil, err
		}
		return m.bm.CountByBook(ctx, bookID)
	}, kernel.Sig("bookId int64"), kernel.Doc("统计某本书的书签数"))

	// ---- 阅读记录 ----
	r.Method("Record.Append", func(ctx context.Context, args []json.RawMessage) (any, error) {
		bookID, err := argID(args, 0, "书籍 ID")
		if err != nil {
			return nil, err
		}
		bookName, err := argString(args, 1)
		if err != nil {
			return nil, err
		}
		chapterIndex, err := argInt(args, 2)
		if err != nil {
			return nil, err
		}
		chapterTitle, err := argString(args, 3)
		if err != nil {
			return nil, err
		}
		return m.rec.Append(ctx, bookID, bookName, chapterIndex, chapterTitle)
	}, kernel.Sig(
		"bookId int64",
		"bookName string",
		"chapterIndex int",
		"chapterTitle string",
	), kernel.Doc("追加阅读记录；同书同日同章只留一条，chapterIndex<0 表示当前位置"))

	r.Method("Record.List", func(ctx context.Context, args []json.RawMessage) (any, error) {
		offset, err := argInt(args, 0)
		if err != nil {
			return nil, err
		}
		limit, err := argInt(args, 1)
		if err != nil {
			return nil, err
		}
		return m.rec.List(ctx, offset, limit)
	}, kernel.Sig("offset int", "limit int"),
		kernel.Doc("分页列出阅读记录，按时间倒序"))

	r.Method("Record.Clear", func(ctx context.Context, args []json.RawMessage) (any, error) {
		beforeDays, err := argInt(args, 0)
		if err != nil {
			return nil, err
		}
		return m.rec.Clear(ctx, beforeDays)
	}, kernel.Sig("beforeDays int"),
		kernel.Doc("清理阅读记录；beforeDays=0 表示全部，返回删除条数"))

	r.Method("Record.Stats", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return m.rec.Stats(ctx)
	}, kernel.Sig(), kernel.Doc("阅读记录聚合统计：天数/书籍数/条数"))

	// ---- CLI（分层解析交给 hosts/cli；与上面的方法共用同一实现）----
	r.Command("bookmark list", func(ctx context.Context, args []string) error {
		bookID, limit, err := parseTwoInts(args, "bookmark list [bookId] [limit]")
		if err != nil {
			return err
		}
		items, err := m.bm.List(ctx, int64(bookID), limit)
		if err != nil {
			return err
		}
		return printJSON(items)
	}, "列出书签：bookmark list [bookId] [limit]")

	r.Command("record list", func(ctx context.Context, args []string) error {
		offset, limit, err := parseTwoInts(args, "record list [offset] [limit]")
		if err != nil {
			return err
		}
		items, err := m.rec.List(ctx, offset, limit)
		if err != nil {
			return err
		}
		return printJSON(items)
	}, "列出阅读记录：record list [offset] [limit]")
}

// ---- 控制面位置参数解码 ----
//
// 手写 handler 拿到的是一组 JSON 值，没有参数名可依，只能按位置取。
// 缺省位置返回零值，让尾参（limit/note 等）可以省略；必填项由服务层校验。

// argInt64 解出 int64；0 视为合法值（bookId=0 在 List 里表示全部）。
func argInt64(args []json.RawMessage, i int) (int64, error) {
	var v int64
	if err := decodeArg(args, i, &v); err != nil {
		return 0, err
	}
	return v, nil
}

// argID 解出必填的 int64 主键类参数；缺省/0 直接报参数错误，
// 免得服务层再判一遍同样的条件。
func argID(args []json.RawMessage, i int, what string) (int64, error) {
	v, err := argInt64(args, i)
	if err != nil {
		return 0, err
	}
	if v == 0 {
		return 0, kernel.Ef(kernel.CodeInvalid, "缺少%s", what)
	}
	return v, nil
}

func argInt(args []json.RawMessage, i int) (int, error) {
	var v int
	if err := decodeArg(args, i, &v); err != nil {
		return 0, err
	}
	return v, nil
}

func argString(args []json.RawMessage, i int) (string, error) {
	var v string
	if err := decodeArg(args, i, &v); err != nil {
		return "", err
	}
	return v, nil
}

// decodeArg 把第 i 个位置参数解到 dst。越界或 null 视为「未传」，保持零值。
func decodeArg(args []json.RawMessage, i int, dst any) error {
	if i >= len(args) || len(args[i]) == 0 || string(args[i]) == "null" {
		return nil
	}
	if err := json.Unmarshal(args[i], dst); err != nil {
		return kernel.Ef(kernel.CodeInvalid, "第 %d 个参数解析失败: %v", i+1, err)
	}
	return nil
}

// parseTwoInts 解析形如 `cmd [a] [b]` 的两个可选整数参数。
// why: CLI 的参数是字符串数组，缺省值就代表「用服务层默认」，
// 因此缺失时返回 0 而不是报错。
func parseTwoInts(args []string, usage string) (int, int, error) {
	var a, b int
	for i := 0; i < 2 && i < len(args); i++ {
		n, err := strconv.Atoi(args[i])
		if err != nil {
			return 0, 0, kernel.Ef(kernel.CodeInvalid, "参数 %q 不是整数，用法: %s", args[i], usage)
		}
		if i == 0 {
			a = n
		} else {
			b = n
		}
	}
	return a, b, nil
}

// printJSON 把 CLI 输出统一成缩进 JSON，脚本可直接管道给 jq。
func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return fmt.Errorf("序列化输出失败: %w", err)
	}
	fmt.Println(string(b))
	return nil
}
