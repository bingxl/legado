package webbook

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
)

// 这一组覆盖 2026-10-29 核对里「不报错但结果错」的正文/详情规则：
//   - ruleContent.title：正文页标题回写章节名
//   - ruleContent.replaceRegex：按行 trim 后替换、再统一补缩进
//   - book.Type：文件型书源必须走 downloadUrls 分支
//   - 搜索结果去重键：只按 bookUrl

func newRulesServer(t *testing.T, pages map[string]string) *httptest.Server {
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
	return srv
}

func TestContentTitleRule(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/c/1.html": `<html><body><h1>真正的章节名</h1><div id="content">正文</div></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "title-test",
		RuleContent: &model.ContentRule{
			Content: "@css:#content@text",
			Title:   "@css:h1@text",
		},
	}
	book := model.NewBook()
	book.BookUrl = srv.URL + "/b/1.html"
	ch := model.NewBookChapter(book.BookUrl)
	ch.Url = srv.URL + "/c/1.html"
	ch.Title = "第12章" // 目录页给的残缺名

	got, err := GetContent(src, book, ch, "")
	if err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	if !strings.Contains(got, "正文") {
		t.Fatalf("正文解析错误: %q", got)
	}
	if ch.Title != "真正的章节名" {
		t.Fatalf("章节名应回写为正文页标题，实际 %q", ch.Title)
	}
}

func TestReplaceRegexTrimAndIndent(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/c/2.html": `<html><body><div id="content">第一行<br> 第二行 <br>第三行</div></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "replace-test",
		RuleContent: &model.ContentRule{
			Content:      "@css:#content@html",
			ReplaceRegex: "##第二行##第二行改",
		},
	}
	book := model.NewBook()
	book.BookUrl = srv.URL + "/b/2.html"
	ch := model.NewBookChapter(book.BookUrl)
	ch.Url = srv.URL + "/c/2.html"

	got, err := GetContent(src, book, ch, "")
	if err != nil {
		t.Fatalf("GetContent 出错: %v", err)
	}
	if !strings.Contains(got, "第二行改") {
		t.Fatalf("替换规则未生效: %q", got)
	}
	for _, line := range strings.Split(got, "\n") {
		if !strings.HasPrefix(line, "\u3000\u3000") {
			t.Fatalf("每行都应补缩进，实际行: %q（全文 %q）", line, got)
		}
		// 缩进之后不应再残留半角空白（说明没有按行 trim）
		if strings.HasPrefix(strings.TrimPrefix(line, "\u3000\u3000"), " ") {
			t.Fatalf("行首空白未 trim: %q（全文 %q）", line, got)
		}
	}
}

// 文件型书源（bookSourceType=3）必须解析 downloadUrls，而不是 tocUrl
func TestFileSourceUsesDownloadUrls(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/f/1.html": `<html><body>
			<h1>下载书籍</h1>
			<a class="dl" href="/dl/1.txt">TXT下载</a>
			<a class="dl" href="/dl/2.txt">TXT下载</a>
			<a class="toc" href="/toc/1.html">目录</a>
		</body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "file-test",
		BookSourceType: model.BookTypeFile,
		RuleBookInfo: &model.BookInfoRule{
			Name:         "@css:h1@text",
			TocUrl:       "@css:a.toc@href",
			DownloadUrls: "@css:a.dl@href",
		},
	}
	book := model.NewBook()
	book.BookUrl = srv.URL + "/f/1.html"

	if err := GetBookInfo(src, book); err != nil {
		t.Fatalf("GetBookInfo 出错: %v", err)
	}
	if !book.IsWebFile() {
		t.Fatalf("文件型书源的 book.Type 应带 webFile 位，实际 %d", book.Type)
	}
	if len(book.DownloadUrls) != 2 {
		t.Fatalf("应解析出 2 个下载地址，实际 %v", book.DownloadUrls)
	}
	if book.TocUrl != "" {
		t.Fatalf("文件型书源不应填 tocUrl，实际 %q", book.TocUrl)
	}
}

// 非文件型书源仍走 tocUrl，且 book.Type 是 legado 位域（文本=1）
func TestTextSourceUsesTocUrl(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/t/1.html": `<html><body><h1>文本书籍</h1><a class="toc" href="/toc/1.html">目录</a></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "text-test",
		RuleBookInfo: &model.BookInfoRule{
			Name:   "@css:h1@text",
			TocUrl: "@css:a.toc@href",
		},
	}
	book := model.NewBook()
	book.BookUrl = srv.URL + "/t/1.html"

	if err := GetBookInfo(src, book); err != nil {
		t.Fatalf("GetBookInfo 出错: %v", err)
	}
	if book.IsWebFile() {
		t.Fatalf("文本型书源不应被判为文件型")
	}
	if book.Type != model.BookFlagText {
		t.Fatalf("文本型 book.Type 应为 1（legado 位域），实际 %d", book.Type)
	}
	if book.TocUrl != srv.URL+"/toc/1.html" {
		t.Fatalf("tocUrl 解析错误: %q", book.TocUrl)
	}
}

// 搜索结果去重：与 SearchBook.equals 一致，只按 bookUrl
func TestSearchDedupeByBookUrl(t *testing.T) {
	srv := newRulesServer(t, map[string]string{
		"/search": `<html><body><ul id="list">
			<li><a class="n" href="/b/1">书名一</a></li>
			<li><a class="n" href="/b/1">书名一（另一个名字）</a></li>
			<li><a class="n" href="/b/2">书名二</a></li>
		</ul></body></html>`,
	})
	src := &model.BookSource{
		BookSourceUrl:  srv.URL,
		BookSourceName: "search-test",
		SearchUrl:      srv.URL + "/search?key={{key}}",
		RuleSearch: &model.SearchRule{
			BookList: "@css:#list li",
			Name:     "@css:a.n@text",
			BookUrl:  "@css:a.n@href",
		},
	}
	list, err := SearchBook(src, "书", 1)
	if err != nil {
		t.Fatalf("SearchBook 出错: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("同一 bookUrl 应只保留 1 条，实际 %d 条: %+v", len(list), list)
	}
}
