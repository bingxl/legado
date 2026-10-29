package webbook

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// 这一组测试覆盖 ruleContent.nextContentUrl（正文分页）的几种形态。
// 对照 Kotlin 版 BookContent.getContent：
//   - 规则只给一个「下一页」时逐页向后抓，撞到「下一章」就停；
//   - 规则一次给多个链接时并发抓全部，且不再递归；
//   - 无论哪种都要有页数上限，避免规则异常时无限请求。

func newPagingFixture(t *testing.T, pages map[string]string) (*httptest.Server, *model.BookSource) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := pages[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, body)
	}))
	t.Cleanup(srv.Close)

	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "paging-test",
		RuleContent: &model.ContentRule{
			Content:        "@css:#content@text",
			NextContentUrl: "@css:a.next@href",
		},
	}
	return srv, src
}

func newPagingBook(srv *httptest.Server, path string) (*model.Book, *model.BookChapter) {
	book := model.NewBook()
	book.BookUrl = srv.URL + path
	book.Origin = srv.URL
	ch := model.NewBookChapter(book.BookUrl)
	ch.Url = srv.URL + path
	return book, ch
}

// 单链分页：每页底部只有一个指向下一页的链接。
func TestGetContentFollowsSingleNextPage(t *testing.T) {
	srv, src := newPagingFixture(t, map[string]string{
		"/c/1.html": `<html><body><div id="content">第一页</div><a class="next" href="/c/2.html">下一页</a></body></html>`,
		"/c/2.html": `<html><body><div id="content">第二页</div><a class="next" href="/c/3.html">下一页</a></body></html>`,
		"/c/3.html": `<html><body><div id="content">第三页</div></body></html>`,
	})
	book, ch := newPagingBook(srv, "/c/1.html")

	got, err := GetContent(src, book, ch, "")
	if err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	for _, want := range []string{"第一页", "第二页", "第三页"} {
		if !strings.Contains(got, want) {
			t.Errorf("正文缺少 %q，实际为: %q", want, got)
		}
	}
}

// 多链分页：首页一次给出多个分页链接。
// 这是此前 Go 实现丢掉的分支——只有 len(nextUrls)==1 才走进循环，
// 多链接时后面的页被直接丢弃。
func TestGetContentFollowsMultipleNextPages(t *testing.T) {
	srv, src := newPagingFixture(t, map[string]string{
		"/m/1.html": `<html><body><div id="content">第一页</div>
			<a class="next" href="/m/2.html">2</a><a class="next" href="/m/3.html">3</a></body></html>`,
		"/m/2.html": `<html><body><div id="content">第二页</div></body></html>`,
		"/m/3.html": `<html><body><div id="content">第三页</div></body></html>`,
	})
	book, ch := newPagingBook(srv, "/m/1.html")

	got, err := GetContent(src, book, ch, "")
	if err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	for _, want := range []string{"第一页", "第二页", "第三页"} {
		if !strings.Contains(got, want) {
			t.Errorf("正文缺少 %q，实际为: %q", want, got)
		}
	}

	// 多链分支不应继续递归：抓完 2、3 页就停，不能再去追它们的「下一页」。
	if n := strings.Count(got, "第一页"); n != 1 {
		t.Errorf("首页被重复抓取 %d 次: %q", n, got)
	}
}

// 「下一页」实际指向下一章：必须刹车，不能把下一章正文拼进来。
func TestGetContentStopsAtNextChapter(t *testing.T) {
	srv, src := newPagingFixture(t, map[string]string{
		"/n/1.html": `<html><body><div id="content">本章正文</div><a class="next" href="/n/2.html">下一章</a></body></html>`,
		"/n/2.html": `<html><body><div id="content">下一章正文</div></body></html>`,
	})
	book, ch := newPagingBook(srv, "/n/1.html")

	got, err := GetContent(src, book, ch, srv.URL+"/n/2.html")
	if err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	if strings.Contains(got, "下一章正文") {
		t.Errorf("把下一章正文拼进了本章: %q", got)
	}
	if !strings.Contains(got, "本章正文") {
		t.Errorf("本章正文缺失: %q", got)
	}
}

// 规则异常（每页都给出一个没见过的地址）时不能无限抓下去。
func TestGetContentRespectsPageLimit(t *testing.T) {
	var hits int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		n := hits
		fmt.Fprintf(w, `<html><body><div id="content">第%d页</div><a class="next" href="/p/%d.html">下一页</a></body></html>`, n, n+1)
	}))
	defer srv.Close()

	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "paging-test",
		RuleContent: &model.ContentRule{
			Content:        "@css:#content@text",
			NextContentUrl: "@css:a.next@href",
		},
	}
	book, ch := newPagingBook(srv, "/p/1.html")

	if _, err := GetContent(src, book, ch, ""); err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	if hits > maxContentPages {
		t.Errorf("分页请求数 %d 超过上限 %d", hits, maxContentPages)
	}
}
