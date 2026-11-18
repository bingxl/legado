package rss

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/core/adapters/persistence/sqlite"
	"github.com/legado/core/kernel"
)

// newTestModule 用独立命名的共享内存库，避免测试之间串数据。
func newTestModule(t *testing.T) *Module {
	t.Helper()
	dsn := fmt.Sprintf("file:%s?mode=memory&cache=shared",
		strings.NewReplacer("/", "_", " ", "_").Replace(t.Name()))
	db, err := sqlite.Open(dsn)
	if err != nil {
		t.Fatalf("打开测试数据库失败: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	m := New(db)
	if err := m.Migrate(context.Background()); err != nil {
		t.Fatalf("建表失败: %v", err)
	}
	return m
}

// feedServer 返回可切换内容的 httptest 服务，用于模拟源站更新。
func feedServer(t *testing.T, body *string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ua := r.Header.Get("User-Agent"); ua == "" {
			t.Errorf("请求未带 User-Agent")
		}
		w.Header().Set("Content-Type", "application/rss+xml; charset=utf-8")
		_, _ = w.Write([]byte(*body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

const feedV1 = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>测试订阅</title>
    <link>https://example.com/</link>
    <description>测试用</description>
    <item>
      <title>第一篇</title>
      <link>/posts/1</link>
      <description>摘要一</description>
      <content:encoded><![CDATA[<p>全文一</p>]]></content:encoded>
      <pubDate>Wed, 18 Nov 2026 08:00:00 +0800</pubDate>
    </item>
    <item>
      <title>第二篇</title>
      <link>/posts/2</link>
      <description>摘要二</description>
      <pubDate>Tue, 17 Nov 2026 08:00:00 +0800</pubDate>
    </item>
  </channel>
</rss>`

// 同名链接改标题 + 新增一篇：用于验证「更新元数据但不覆盖已读/收藏」。
const feedV2 = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>测试订阅</title>
    <link>https://example.com/</link>
    <description>测试用</description>
    <item>
      <title>第一篇（已更正）</title>
      <link>/posts/1</link>
      <description>摘要一（已更正）</description>
      <content:encoded><![CDATA[<p>全文一（已更正）</p>]]></content:encoded>
      <pubDate>Wed, 18 Nov 2026 08:00:00 +0800</pubDate>
    </item>
    <item>
      <title>第二篇</title>
      <link>/posts/2</link>
      <description>摘要二</description>
      <pubDate>Tue, 17 Nov 2026 08:00:00 +0800</pubDate>
    </item>
    <item>
      <title>第三篇</title>
      <link>/posts/3</link>
      <description>摘要三</description>
      <pubDate>Thu, 19 Nov 2026 08:00:00 +0800</pubDate>
    </item>
  </channel>
</rss>`

// 覆盖主链路：新增源 → 刷新 → 入库 → 去重更新不覆盖用户状态 → 收藏 → 删除级联。
func TestRefreshAndArticleState(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)
	svc := m.svc

	body := feedV1
	srv := feedServer(t, &body)

	src, err := svc.SaveSource(ctx, SourceInput{
		Name:  "测试订阅",
		URL:   srv.URL + "/feed.xml",
		Group: "技术",
	})
	if err != nil {
		t.Fatalf("新增订阅源失败: %v", err)
	}
	if src.ID == 0 || !src.Enabled {
		t.Fatalf("新增结果异常: %+v", src)
	}

	first, err := svc.RefreshSource(ctx, src.ID)
	if err != nil {
		t.Fatalf("刷新失败: %v", err)
	}
	if first.Added != 2 || first.Updated != 0 {
		t.Fatalf("首次刷新统计异常: %+v", first)
	}

	articles, err := svc.ListArticles(ctx, 0, false, 0, 10)
	if err != nil {
		t.Fatalf("列出文章失败: %v", err)
	}
	if len(articles) != 2 {
		t.Fatalf("文章数 = %d, 期望 2", len(articles))
	}
	// 按 pub_date 倒序，第一篇发布时间更晚。
	if articles[0].Title != "第一篇" {
		t.Errorf("排序异常，首篇 = %q", articles[0].Title)
	}
	if articles[0].SourceName != "测试订阅" {
		t.Errorf("来源名未关联: %q", articles[0].SourceName)
	}
	// 相对链接必须补成绝对地址，否则去重键不稳定。
	if articles[0].Link != srv.URL+"/posts/1" {
		t.Errorf("相对链接未解析: %q", articles[0].Link)
	}
	if !strings.Contains(articles[0].Content, "全文一") {
		t.Errorf("content:encoded 未入库: %q", articles[0].Content)
	}

	var firstID, secondID int64
	for _, a := range articles {
		switch a.Title {
		case "第一篇":
			firstID = a.ID
		case "第二篇":
			secondID = a.ID
		}
	}
	if err := svc.MarkRead(ctx, firstID, true); err != nil {
		t.Fatalf("标记已读失败: %v", err)
	}
	fav, err := svc.ToggleFavorite(ctx, secondID)
	if err != nil || !fav {
		t.Fatalf("收藏失败: fav=%v err=%v", fav, err)
	}

	// 源站更新：帖子 1 改标题，新增帖子 3。
	body = feedV2
	second, err := svc.RefreshSource(ctx, src.ID)
	if err != nil {
		t.Fatalf("二次刷新失败: %v", err)
	}
	if second.Added != 1 || second.Updated != 2 {
		t.Fatalf("二次刷新统计异常: %+v", second)
	}

	all, err := svc.ListArticles(ctx, 0, false, 0, 10)
	if err != nil {
		t.Fatalf("列出文章失败: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("去重后文章数 = %d, 期望 3", len(all))
	}
	for _, a := range all {
		if a.ID == firstID {
			if a.Title != "第一篇（已更正）" {
				t.Errorf("标题未更新: %q", a.Title)
			}
			if !a.Read {
				t.Error("刷新覆盖了已读状态")
			}
		}
		if a.ID == secondID && !a.Favorite {
			t.Error("刷新覆盖了收藏状态")
		}
	}

	// 只列未读：第一篇已读，应剩 2 篇。
	unread, err := svc.ListArticles(ctx, src.ID, true, 0, 10)
	if err != nil {
		t.Fatalf("列出未读失败: %v", err)
	}
	if len(unread) != 2 {
		t.Fatalf("未读数 = %d, 期望 2", len(unread))
	}

	counts, err := svc.UnreadCount(ctx)
	if err != nil {
		t.Fatalf("统计未读失败: %v", err)
	}
	if counts[src.ID] != 2 {
		t.Errorf("按源未读 = %d, 期望 2", counts[src.ID])
	}

	favorites, err := svc.ListFavorites(ctx)
	if err != nil {
		t.Fatalf("列出收藏失败: %v", err)
	}
	if len(favorites) != 1 || favorites[0].ID != secondID {
		t.Fatalf("收藏列表异常: %+v", favorites)
	}

	// 取消收藏。
	if fav, err := svc.ToggleFavorite(ctx, secondID); err != nil || fav {
		t.Fatalf("取消收藏失败: fav=%v err=%v", fav, err)
	}
	if favorites, _ = svc.ListFavorites(ctx); len(favorites) != 0 {
		t.Errorf("取消后收藏列表应为空，得到 %d 条", len(favorites))
	}

	// 删除源应连带删除文章。
	if err := svc.DeleteSource(ctx, src.ID); err != nil {
		t.Fatalf("删除订阅源失败: %v", err)
	}
	if all, _ = svc.ListArticles(ctx, 0, false, 0, 10); len(all) != 0 {
		t.Errorf("删除源后仍有 %d 篇文章", len(all))
	}
	if err := svc.DeleteSource(ctx, src.ID); err == nil {
		t.Error("重复删除应返回 NOT_FOUND")
	}
}

// RefreshAll 只刷新启用的源；RefreshSource 显式调用时不受开关限制。
func TestRefreshAllSkipsDisabled(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)
	svc := m.svc

	body := feedV1
	srv := feedServer(t, &body)

	enabled, err := svc.SaveSource(ctx, SourceInput{Name: "启用", URL: srv.URL + "/a.xml"})
	if err != nil {
		t.Fatalf("新增源失败: %v", err)
	}
	disabled, err := svc.SaveSource(ctx, SourceInput{Name: "停用", URL: srv.URL + "/b.xml", Enabled: boolPtr(false)})
	if err != nil {
		t.Fatalf("新增源失败: %v", err)
	}

	res, err := svc.RefreshAll(ctx)
	if err != nil {
		t.Fatalf("刷新全部失败: %v", err)
	}
	if res.Sources != 1 || res.Added != 2 {
		t.Fatalf("刷新全部统计异常: %+v", res)
	}

	if _, err := svc.RefreshSource(ctx, disabled.ID); err != nil {
		t.Fatalf("显式刷新停用源应允许: %v", err)
	}

	if err := svc.SetEnabled(ctx, disabled.ID, true); err != nil {
		t.Fatalf("启用失败: %v", err)
	}
	res, err = svc.RefreshAll(ctx)
	if err != nil {
		t.Fatalf("刷新全部失败: %v", err)
	}
	if res.Sources != 2 {
		t.Fatalf("启用后应刷新 2 个源，得到 %d", res.Sources)
	}
	// 两个源都还没文章以外的差异；第二个源第二次刷新是纯更新。
	if res.Added != 0 {
		t.Errorf("二次刷新不应新增，得到 %d", res.Added)
	}

	_ = enabled
}

func TestSaveSourceValidationAndUpdate(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)
	svc := m.svc

	if _, err := svc.SaveSource(ctx, SourceInput{Name: "空地址"}); err == nil {
		t.Fatal("空地址应被拒绝")
	}
	if _, err := svc.SaveSource(ctx, SourceInput{Name: "本地", URL: "file:///etc/passwd"}); err == nil {
		t.Fatal("非 http(s) 地址应被拒绝")
	}

	src, err := svc.SaveSource(ctx, SourceInput{URL: "https://example.com/feed"})
	if err != nil {
		t.Fatalf("新增失败: %v", err)
	}
	// 名称留空时回落到地址，避免列表出现空白项。
	if src.Name != "https://example.com/feed" {
		t.Errorf("默认名称 = %q", src.Name)
	}

	// 更新时不传 enabled，应保持原值。
	updated, err := svc.SaveSource(ctx, SourceInput{ID: src.ID, Name: "改名", URL: src.URL, Group: "分组"})
	if err != nil {
		t.Fatalf("更新失败: %v", err)
	}
	if updated.Name != "改名" || updated.Group != "分组" || !updated.Enabled {
		t.Errorf("更新结果异常: %+v", updated)
	}

	list, err := svc.ListSources(ctx)
	if err != nil || len(list) != 1 {
		t.Fatalf("列表异常: len=%d err=%v", len(list), err)
	}
}

// 坏源不应阻塞 RefreshAll：错误进 Errors，其他源照常入库。
func TestRefreshAllCollectsErrors(t *testing.T) {
	ctx := context.Background()
	m := newTestModule(t)
	svc := m.svc

	body := feedV1
	good := feedServer(t, &body)
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(bad.Close)

	if _, err := svc.SaveSource(ctx, SourceInput{Name: "正常", URL: good.URL + "/feed.xml"}); err != nil {
		t.Fatalf("新增源失败: %v", err)
	}
	if _, err := svc.SaveSource(ctx, SourceInput{Name: "坏源", URL: bad.URL + "/feed.xml"}); err != nil {
		t.Fatalf("新增源失败: %v", err)
	}

	res, err := svc.RefreshAll(ctx)
	if err != nil {
		t.Fatalf("刷新全部不应整体失败: %v", err)
	}
	if res.Added != 2 {
		t.Errorf("正常源应入库 2 篇，得到 %d", res.Added)
	}
	if len(res.Errors) != 1 || !strings.Contains(res.Errors[0], "坏源") {
		t.Errorf("坏源错误未收集: %+v", res.Errors)
	}
}

func boolPtr(v bool) *bool { return &v }

// 方法名与 CLI 路径是 UI / 宿主的公开契约，改名属于破坏性变更，用测试钉住。
func TestRegisterWiresMethodsAndCommands(t *testing.T) {
	m := newTestModule(t)
	reg := kernel.NewRegistry()
	m.Register(reg)

	methods := []string{
		"Rss.Source.List", "Rss.Source.Save", "Rss.Source.Delete", "Rss.Source.SetEnabled",
		"Rss.Article.List", "Rss.Article.Refresh", "Rss.Article.MarkRead",
		"Rss.Article.Favorite", "Rss.Favorite.List", "Rss.Unread.Count",
	}
	for _, name := range methods {
		meta, ok := reg.Lookup(name)
		if !ok {
			t.Errorf("方法未注册: %s", name)
			continue
		}
		if name == "Rss.Article.List" && meta.Arity != 4 {
			t.Errorf("Rss.Article.List arity = %d, 期望 4", meta.Arity)
		}
	}

	cmds := map[string]bool{}
	for _, c := range reg.Commands() {
		cmds[c.Path] = true
	}
	for _, path := range []string{"rss list", "rss refresh"} {
		if !cmds[path] {
			t.Errorf("CLI 命令未注册: %s", path)
		}
	}
}
