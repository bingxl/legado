package webbook_test

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/download"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/webbook"
)

// 测试用站点：/search 下发 cookie，/c/:id 必须携带该 cookie
func newTestServer(t *testing.T) *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/search", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "token", Value: "abc123", Path: "/", MaxAge: 3600})
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<html><body>
		<div class="book"><h3><a href="/book/1">测试书籍</a></h3><span class="au">测试作者</span></div>
		<div class="book"><h3><a href="/book/2">第二本书</a></h3><span class="au">另一作者</span></div>
		</body></html>`)
	})
	mux.HandleFunc("/book/", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "token", Value: "abc123", Path: "/", MaxAge: 3600})
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<html><body>
		<h1>测试书籍</h1><span class="author">测试作者</span>
		<a class="toc" href="/toc">目录</a>
		</body></html>`)
	})
	mux.HandleFunc("/toc", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprint(w, `<html><body><ul id="chapters">
		<li><a href="/c/1">第一章 开端</a></li>
		<li><a href="/c/2">第二章 发展</a></li>
		</ul></body></html>`)
	})
	mux.HandleFunc("/c/", func(w http.ResponseWriter, r *http.Request) {
		if c, err := r.Cookie("token"); err != nil || c.Value != "abc123" {
			http.Error(w, "missing cookie", http.StatusForbidden)
			return
		}
		id := strings.TrimPrefix(r.URL.Path, "/c/")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		fmt.Fprintf(w, `<html><body><div class="content">这是第 %s 章的正文内容。</div></body></html>`, id)
	})
	return httptest.NewServer(mux)
}

func testSource(base string) *model.BookSource {
	raw := fmt.Sprintf(`{
		"bookSourceUrl": "%s",
		"bookSourceName": "测试源",
		"bookSourceType": 0,
		"enabledCookieJar": true,
		"searchUrl": "/search?key={{key}}",
		"ruleSearch": {
			"bookList": "div.book",
			"name": "h3 a@text",
			"author": "span.au@text",
			"bookUrl": "h3 a@href"
		},
		"ruleBookInfo": {
			"name": "h1@text",
			"author": "span.author@text",
			"tocUrl": "a.toc@href"
		},
		"ruleToc": {
			"chapterList": "ul#chapters li",
			"chapterName": "a@text",
			"chapterUrl": "a@href"
		},
		"ruleContent": {
			"content": "div.content@textNodes"
		}
	}`, base)
	var s model.BookSource
	if err := json.Unmarshal([]byte(raw), &s); err != nil {
		panic(err)
	}
	return &s
}

func TestEndToEnd(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()
	store.Default().RemoveCookie(srv.URL)
	src := testSource(srv.URL)

	// 1. 搜索
	list, err := webbook.SearchBook(src, "测试", 1)
	if err != nil {
		t.Fatalf("搜索失败: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("搜索结果数量错误: %d", len(list))
	}
	if list[0].Name != "测试书籍" || list[0].Author != "测试作者" {
		t.Fatalf("搜索结果内容错误: %+v", list[0])
	}
	if !strings.HasSuffix(list[0].BookUrl, "/book/1") {
		t.Fatalf("书籍链接错误: %s", list[0].BookUrl)
	}
	t.Logf("搜索 OK: %s / %s", list[0].Name, list[0].Author)

	// 2. Cookie 是否已自动保存
	ck := store.Default().GetCookie(srv.URL)
	if !strings.Contains(ck, "token=abc123") {
		t.Fatalf("Cookie 未自动保存: %q", ck)
	}
	t.Logf("Cookie 自动保存 OK: %s", ck)

	// 3. 详情
	book := list[0].ToBook()
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("获取详情失败: %v", err)
	}
	if book.Name != "测试书籍" || book.Author != "测试作者" {
		t.Fatalf("详情内容错误: %+v", book)
	}
	if !strings.HasSuffix(book.TocUrl, "/toc") {
		t.Fatalf("目录链接错误: %s", book.TocUrl)
	}
	t.Logf("详情 OK: %s toc=%s", book.Name, book.TocUrl)

	// 4. 目录
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("获取目录失败: %v", err)
	}
	if len(chapters) != 2 {
		t.Fatalf("目录数量错误: %d", len(chapters))
	}
	if chapters[0].Title != "第一章 开端" {
		t.Fatalf("章节名错误: %q", chapters[0].Title)
	}
	t.Logf("目录 OK: %d 章，首章 %s", len(chapters), chapters[0].Title)

	// 5. 正文（需携带 cookie，用于验证 cookie 自动注入）
	content, err := webbook.GetContent(src, book, chapters[0], "")
	if err != nil {
		t.Fatalf("获取正文失败: %v", err)
	}
	if !strings.Contains(content, "这是第 1 章的正文内容") {
		t.Fatalf("正文内容错误: %q", content)
	}
	t.Logf("正文 OK（Cookie 自动注入成功）: %s", content)
}

func TestDownloadText(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()
	store.Default().RemoveCookie(srv.URL)
	src := testSource(srv.URL)

	book := model.NewBook()
	book.BookUrl = srv.URL + "/book/1"
	dir := t.TempDir()
	res, err := download.DownloadBook(src, book, download.Options{
		OutDir:  dir,
		Format:  "txt",
		Workers: 2,
	})
	if err != nil {
		t.Fatalf("下载失败: %v", err)
	}
	if res.Chapters != 2 {
		t.Fatalf("下载章节数错误: %d", res.Chapters)
	}
	if len(res.Failed) != 0 {
		t.Fatalf("存在失败章节: %v", res.Failed)
	}
	data, err := readFileString(res.Path)
	if err != nil {
		t.Fatalf("读取产物失败: %v", err)
	}
	if !strings.Contains(data, "第一章 开端") || !strings.Contains(data, "这是第 1 章的正文内容") {
		t.Fatalf("产物内容错误: %q", data)
	}
	t.Logf("下载 OK: %s", res.String())
}

func TestJsExtension(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()
	store.Default().RemoveCookie(srv.URL)
	src := testSource(srv.URL)
	// 用 JS 规则调用 java.ajax 抓取页面并取标题
	src.RuleBookInfo.Name = "@js:var h=java.ajax(book.bookUrl); h.match(/<h1>([^<]+)<\\/h1>/)[1]"
	book := model.NewBook()
	book.BookUrl = srv.URL + "/book/1"
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("JS 扩展调用失败: %v", err)
	}
	if book.Name != "测试书籍" {
		t.Fatalf("java.ajax 结果错误: %q", book.Name)
	}
	t.Logf("java.ajax OK: %s", book.Name)
}

func TestPutGetVariableInJS(t *testing.T) {
	srv := newTestServer(t)
	defer srv.Close()
	store.Default().RemoveCookie(srv.URL)
	src := testSource(srv.URL)
	// 在详情 init 中写入变量，正文规则中用 @get 读取
	src.RuleBookInfo.Init = "@js:java.put('myTag','标记值'); result"
	book := model.NewBook()
	book.BookUrl = srv.URL + "/book/1"
	if err := webbook.GetBookInfo(src, book); err != nil {
		t.Fatalf("详情失败: %v", err)
	}
	src.RuleContent.Content = "@get:{myTag}"
	chapters, err := webbook.GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("目录失败: %v", err)
	}
	c, err := webbook.GetContent(src, book, chapters[0], "")
	if err != nil {
		t.Fatalf("正文失败: %v", err)
	}
	if c != "标记值" {
		t.Fatalf("@get 读取变量错误: %q", c)
	}
	t.Logf("java.put / @get 变量链路 OK: %s", c)
}

func readFileString(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}
