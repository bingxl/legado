// Package rss 是 RSS 域模块（订阅源、文章、收藏、阅读）。
//
// 拉取只在 headless 侧做：解析与入库都走 Go，UI 只消费列表与未读数，
// 这样定时刷新、批量刷新在任何宿主下都是同一份实现。
package rss

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// Module 实现 kernel.Module。
type Module struct {
	db  *sqlite.DB
	svc *Service
}

// New 构造模块。db 用于本域自有表（不要碰其他域的表）。
//
// ua 可选：装配处（registry）当前只传 db，保留变参是为了不改装配代码；
// 宿主需要换 UA 时直接多传一个字符串即可。
func New(db *sqlite.DB, ua ...string) *Module {
	agent := ""
	if len(ua) > 0 {
		agent = ua[0]
	}
	return &Module{db: db, svc: NewService(db, agent)}
}

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
	CREATE UNIQUE INDEX IF NOT EXISTS idx_rss_article_link ON rss_article(source_id, link);
	CREATE INDEX IF NOT EXISTS idx_rss_article_list ON rss_article(source_id, pub_date DESC);`)
}

// Register 把本域能力交给内核。
func (m *Module) Register(r *kernel.Registry) {
	bind(r, "Rss.Source.List", m.sourceList, "列出订阅源（含未读数）")
	bind(r, "Rss.Source.Save", m.sourceSave, "新增或更新订阅源", "SourceInput")
	bind(r, "Rss.Source.Delete", m.sourceDelete, "删除订阅源及其文章", "int64")
	bind(r, "Rss.Source.SetEnabled", m.sourceSetEnabled, "启用/停用订阅源", "int64", "bool")

	bind(r, "Rss.Article.List", m.articleList, "列出文章（sourceId=0 表示全部）", "int64", "bool", "int", "int")
	bind(r, "Rss.Article.Refresh", m.articleRefresh, "刷新订阅（sourceId=0 表示全部启用源）", "int64")
	bind(r, "Rss.Article.MarkRead", m.articleMarkRead, "设置文章已读状态", "int64", "bool")
	bind(r, "Rss.Article.Favorite", m.articleFavorite, "切换文章收藏，返回新状态", "int64")
	bind(r, "Rss.Favorite.List", m.favoriteList, "列出收藏文章")
	bind(r, "Rss.Unread.Count", m.unreadCount, "按源统计未读数")

	r.Command("rss list", m.cliList, "列出订阅源与未读数")
	r.Command("rss refresh", m.cliRefresh, "刷新全部启用的订阅源")
}

// bind 注册手写方法并补齐参数签名。
//
// 手写 handler 的参数在闭包里，r.Method 无法像反射那样拿到签名；
// 不显式声明的话 `legado schema` 会把 arity 导成 0，Dart 侧就无法校验参数个数。
func bind(r *kernel.Registry, name string, h kernel.Handler, doc string, params ...string) {
	r.Method(name, h, kernel.Sig(params...), kernel.Doc(doc))
}

func (m *Module) sourceList(ctx context.Context, args []json.RawMessage) (any, error) {
	return m.svc.ListSources(ctx)
}

func (m *Module) sourceSave(ctx context.Context, args []json.RawMessage) (any, error) {
	var in SourceInput
	if err := decodeArgs(args, &in); err != nil {
		return nil, err
	}
	return m.svc.SaveSource(ctx, in)
}

func (m *Module) sourceDelete(ctx context.Context, args []json.RawMessage) (any, error) {
	var id int64
	if err := decodeArgs(args, &id); err != nil {
		return nil, err
	}
	if err := m.svc.DeleteSource(ctx, id); err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Module) sourceSetEnabled(ctx context.Context, args []json.RawMessage) (any, error) {
	var id int64
	var enabled bool
	if err := decodeArgs(args, &id, &enabled); err != nil {
		return nil, err
	}
	if err := m.svc.SetEnabled(ctx, id, enabled); err != nil {
		return nil, err
	}
	return true, nil
}

// articleList 的参数顺序与 README 的示例一致：
// (sourceId int64, onlyUnread bool, offset int, limit int)。
func (m *Module) articleList(ctx context.Context, args []json.RawMessage) (any, error) {
	var sourceID int64
	var onlyUnread bool
	var offset, limit int
	if err := decodeArgs(args, &sourceID, &onlyUnread, &offset, &limit); err != nil {
		return nil, err
	}
	return m.svc.ListArticles(ctx, sourceID, onlyUnread, offset, limit)
}

func (m *Module) articleRefresh(ctx context.Context, args []json.RawMessage) (any, error) {
	var sourceID int64
	if err := decodeArgs(args, &sourceID); err != nil {
		return nil, err
	}
	if sourceID == 0 {
		return m.svc.RefreshAll(ctx)
	}
	return m.svc.RefreshSource(ctx, sourceID)
}

func (m *Module) articleMarkRead(ctx context.Context, args []json.RawMessage) (any, error) {
	var id int64
	var read bool
	if err := decodeArgs(args, &id, &read); err != nil {
		return nil, err
	}
	if err := m.svc.MarkRead(ctx, id, read); err != nil {
		return nil, err
	}
	return true, nil
}

func (m *Module) articleFavorite(ctx context.Context, args []json.RawMessage) (any, error) {
	var id int64
	if err := decodeArgs(args, &id); err != nil {
		return nil, err
	}
	return m.svc.ToggleFavorite(ctx, id)
}

func (m *Module) favoriteList(ctx context.Context, args []json.RawMessage) (any, error) {
	return m.svc.ListFavorites(ctx)
}

func (m *Module) unreadCount(ctx context.Context, args []json.RawMessage) (any, error) {
	return m.svc.UnreadCount(ctx)
}

// cliList 打印「未读数 + 名称 + 地址」，与 UI 列表的首屏信息一致。
func (m *Module) cliList(ctx context.Context, _ []string) error {
	sources, err := m.svc.ListSources(ctx)
	if err != nil {
		return err
	}
	if len(sources) == 0 {
		fmt.Println("（没有订阅源）")
		return nil
	}
	fmt.Printf("%-8s %-6s %-8s %s\n", "ID", "未读", "状态", "名称 / 地址")
	for _, s := range sources {
		state := "启用"
		if !s.Enabled {
			state = "停用"
		}
		fmt.Printf("%-8d %-6d %-8s %s\n", s.ID, s.UnreadCount, state, s.Name)
		fmt.Printf("%-8s %-6s %-8s %s\n", "", "", "", s.URL)
	}
	return nil
}

// cliRefresh 逐条打印失败原因：批量刷新时「哪个源坏了」比总数更重要。
func (m *Module) cliRefresh(ctx context.Context, _ []string) error {
	res, err := m.svc.RefreshAll(ctx)
	if err != nil {
		return err
	}
	fmt.Printf("刷新完成：源 %d 个，新增 %d 篇，更新 %d 篇，跳过 %d 篇\n",
		res.Sources, res.Added, res.Updated, res.Skipped)
	for _, e := range res.Errors {
		fmt.Printf("  ! %s\n", e)
	}
	return nil
}

// decodeArgs 按位置把 JSON 参数解到目标变量；缺省/ null 保持零值。
func decodeArgs(args []json.RawMessage, dst ...any) error {
	for i, target := range dst {
		if i >= len(args) || len(args[i]) == 0 || string(args[i]) == "null" {
			continue
		}
		if err := json.Unmarshal(args[i], target); err != nil {
			return kernel.Ef(kernel.CodeInvalid, "第 %d 个参数解析失败: %v", i+1, err)
		}
	}
	return nil
}
