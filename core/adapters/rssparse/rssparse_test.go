package rssparse

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func parseFixture(t *testing.T, name string) *Feed {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("读取 fixture %s 失败: %v", name, err)
	}
	feed, err := Parse(data)
	if err != nil {
		t.Fatalf("解析 %s 失败: %v", name, err)
	}
	return feed
}

func TestParseRSS2(t *testing.T) {
	feed := parseFixture(t, "rss2.xml")

	if feed.Title != "示例科技新闻" {
		t.Errorf("频道标题 = %q", feed.Title)
	}
	if feed.Link != "https://example.com/" {
		t.Errorf("频道链接 = %q", feed.Link)
	}
	if len(feed.Items) != 2 {
		t.Fatalf("条目数 = %d, 期望 2", len(feed.Items))
	}

	first := feed.Items[0]
	if first.Title != "Go 1.27 发布" {
		t.Errorf("标题 = %q", first.Title)
	}
	if first.Link != "https://example.com/posts/go127" {
		t.Errorf("链接 = %q", first.Link)
	}
	// CDATA 里的 HTML 应原样保留，CDATA 包裹本身要被剥掉。
	if !strings.Contains(first.Description, "<p>Go 1.27 带来了若干改进。</p>") {
		t.Errorf("CDATA 描述未正确解析: %q", first.Description)
	}
	if !strings.Contains(first.Author, "编辑部") {
		t.Errorf("作者 = %q", first.Author)
	}
	want := time.Date(2026, 11, 18, 1, 30, 0, 0, time.UTC)
	if !first.PubDate.Equal(want) {
		t.Errorf("发布时间 = %v, 期望 %v", first.PubDate, want)
	}
	// 没有 content:encoded 时正文回落到 description。
	if first.Content != first.Description {
		t.Errorf("正文应回落到描述，得到 %q", first.Content)
	}

	second := feed.Items[1]
	if second.Author != "" {
		t.Errorf("第二篇不应有作者，得到 %q", second.Author)
	}
	if !strings.Contains(second.Description, "纯文本摘要 & 转义实体") {
		t.Errorf("转义实体未解码: %q", second.Description)
	}
}

func TestParseRSS2ContentEncoded(t *testing.T) {
	feed := parseFixture(t, "rss2_content.xml")

	if len(feed.Items) != 2 {
		t.Fatalf("条目数 = %d, 期望 2", len(feed.Items))
	}
	first := feed.Items[0]
	if !strings.Contains(first.Content, "正文第二段") {
		t.Errorf("content:encoded 未作为正文: %q", first.Content)
	}
	if strings.Contains(first.Content, "摘要") {
		t.Errorf("有全文时不应混入摘要: %q", first.Content)
	}
	if first.Description != "摘要：只讲结论。" {
		t.Errorf("描述 = %q", first.Description)
	}
	if first.Author != "张三" {
		t.Errorf("dc:creator 未作为作者: %q", first.Author)
	}
	if first.PubDate.IsZero() {
		t.Error("RFC3339 时间解析失败")
	}

	second := feed.Items[1]
	if second.Content != second.Description {
		t.Errorf("无全文时正文应回落到摘要: content=%q desc=%q", second.Content, second.Description)
	}
}

func TestParseAtom(t *testing.T) {
	feed := parseFixture(t, "atom.xml")

	if feed.Title != "Atom 示例博客" {
		t.Errorf("标题 = %q", feed.Title)
	}
	// rel="self" 排在 alternate 之前，必须选 alternate。
	if feed.Link != "https://atom.example.net/" {
		t.Errorf("站点链接 = %q", feed.Link)
	}
	if feed.Description != "记录工程实践" {
		t.Errorf("副标题 = %q", feed.Description)
	}
	if len(feed.Items) != 2 {
		t.Fatalf("条目数 = %d, 期望 2", len(feed.Items))
	}

	first := feed.Items[0]
	if first.Title != "订阅解析的三件事" {
		t.Errorf("标题 = %q", first.Title)
	}
	if first.Link != "https://atom.example.net/three-things" {
		t.Errorf("条目链接 = %q", first.Link)
	}
	if !strings.Contains(first.Content, "<p>Atom 的 content 才是正文。</p>") {
		t.Errorf("content 未正确解析: %q", first.Content)
	}
	if first.Description != "摘要不是正文。" {
		t.Errorf("摘要 = %q", first.Description)
	}
	if first.Author != "王五" {
		t.Errorf("作者 = %q", first.Author)
	}
	if first.PubDate.UTC() != time.Date(2026, 11, 18, 8, 15, 0, 0, time.UTC) {
		t.Errorf("published 应优先于 updated: %v", first.PubDate)
	}

	second := feed.Items[1]
	// 没有 rel 的 link 按 Atom 约定即 alternate。
	if second.Link != "https://atom.example.net/summary-only" {
		t.Errorf("无 rel 的链接未被选中: %q", second.Link)
	}
	if second.Content != "这段摘要就是正文。" {
		t.Errorf("无 content 时正文应回落到 summary: %q", second.Content)
	}
	if second.PubDate.IsZero() {
		t.Error("只有 updated 时也应取到时间")
	}
}

func TestParseUnsupportedRoot(t *testing.T) {
	if _, err := Parse([]byte(`<?xml version="1.0"?><html><body/></html>`)); err == nil {
		t.Fatal("非订阅格式应返回错误")
	}
	if _, err := Parse(nil); err == nil {
		t.Fatal("空内容应返回错误")
	}
}

func TestResolveURL(t *testing.T) {
	got := ResolveURL("https://example.com/feed/index.xml", "../posts/1")
	if got != "https://example.com/posts/1" {
		t.Errorf("相对链接解析 = %q", got)
	}
}
