// Package rss 是 RSS 域模块（订阅源、文章、收藏、阅读）。
//
// 现状：迁移期占位。业务实现由并行开发者填充，契约见 core/modules/README.md。
// 本模块只允许改 core/modules/rss/ 与 core/adapters/rssparse/。
package rss

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

// New 构造模块。db 用于本域自有表（不要碰其他域的表）。
func New(db *sqlite.DB) *Module { return &Module{db: db} }

// Name 返回模块名。
func (m *Module) Name() string { return "rss" }

// DependsOn 声明依赖模块。
func (m *Module) DependsOn() []string { return nil }

// Migrate 建表（幂等）。rt.Open 会在 Boot 前调用。
func (m *Module) Migrate(ctx context.Context) error {
	return m.db.EnsureSchema(ctx, `CREATE TABLE IF NOT EXISTS rss_source (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		url TEXT NOT NULL,
		group_name TEXT NOT NULL DEFAULT '',
		enabled INTEGER NOT NULL DEFAULT 1,
		sort_order INTEGER NOT NULL DEFAULT 0,
		created_at INTEGER NOT NULL DEFAULT (unixepoch()),
		updated_at INTEGER NOT NULL DEFAULT (unixepoch())
	);
	CREATE TABLE IF NOT EXISTS rss_article (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		source_id INTEGER NOT NULL,
		title TEXT NOT NULL,
		link TEXT NOT NULL,
		description TEXT NOT NULL DEFAULT '',
		content TEXT NOT NULL DEFAULT '',
		author TEXT NOT NULL DEFAULT '',
		pub_date INTEGER NOT NULL DEFAULT 0,
		read INTEGER NOT NULL DEFAULT 0,
		favorite INTEGER NOT NULL DEFAULT 0,
		created_at INTEGER NOT NULL DEFAULT (unixepoch())
	);
	CREATE UNIQUE INDEX IF NOT EXISTS idx_rss_article_link ON rss_article(source_id, link);`)
}

// Register 把本域能力交给内核。
func (m *Module) Register(r *kernel.Registry) {
	r.Method("Rss.Ping", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return "pong", nil
	}, kernel.Doc("占位方法：RSS 域待实现"))
}
