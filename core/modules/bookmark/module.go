// Package bookmark 是书签与阅读记录域：书签增删查、阅读记录流水、进度同步。
//
// 现状：迁移期占位。注意与 Shelf（阅读进度当前值）的分工：
// 本模块记录**流水与位置标记**，Shelf 负责「这本书现在读到哪」。
package bookmark

import (
	"context"
	"encoding/json"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// Module 实现 kernel.Module。
type Module struct {
	db *sqlite.DB
}

// New 构造模块。
func New(db *sqlite.DB) *Module { return &Module{db: db} }

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
	CREATE INDEX IF NOT EXISTS idx_read_record_time ON read_record(read_at DESC);`)
}

// Register 把本域能力交给内核。
func (m *Module) Register(r *kernel.Registry) {
	r.Method("Bookmark.Ping", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return "pong", nil
	}, kernel.Doc("占位方法：书签域待实现"))
}
