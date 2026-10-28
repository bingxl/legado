package webbook

// 目录多页（nextTocUrl 一次给出多个地址）的行为回归：
// 所有页的章节都必须进列表，且顺序按地址顺序稳定——不能只取第一页。

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/model"
)

func TestAnalyzeChapterListMultiNextPage(t *testing.T) {
	tocPage := func(chapters ...string) string {
		var sb strings.Builder
		sb.WriteString(`<div class="list">`)
		for _, c := range chapters {
			sb.WriteString(`<a href="` + c + `.html">` + c + `</a>`)
		}
		sb.WriteString(`</div>`)
		return sb.String()
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/page-2.html", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(tocPage("b1")))
	})
	mux.HandleFunc("/page-3.html", func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(tocPage("c1")))
	})
	// NewTestServer 默认走内存网络，urlx 用的普通 http.Client 到不了；
	// Start() 起真实回环监听后 URL 才有值
	srv := httptest.NewTestServer(t, mux)
	srv.Start()

	src := &model.BookSource{
		BookSourceUrl:  "toc-test",
		BookSourceName: "目录多页测试",
		RuleToc: &model.TocRule{
			ChapterList: ".list a",
			ChapterName: "text",
			ChapterUrl:  "href",
			// 首页同时给出两个下一页地址 → 走并发分支
			NextTocUrl: ".pages a@href",
		},
	}
	book := model.NewBook()
	tocURL := srv.URL + "/toc"
	book.BookUrl = srv.URL + "/book/1"

	rec := &sinkRecorder{}
	debug.SetSink(rec)
	defer debug.SetSink(nil)

	body := tocPage("a1", "a2") +
		`<div class="pages"><a href="page-2.html">2</a><a href="page-3.html">3</a></div>`
	chapters, err := analyzeChapterList(src, book, tocURL, tocURL, body)
	if err != nil {
		t.Fatalf("目录解析失败: %v", err)
	}

	var titles []string
	for _, c := range chapters {
		titles = append(titles, c.Title)
	}
	if want := "a1,a2,b1,c1"; strings.Join(titles, ",") != want {
		t.Errorf("章节顺序为 %v，应为 %s（多页必须全部抓到且按地址顺序）", titles, want)
	}
	got := rec.all()
	if !strings.Contains(got, "◇并发解析目录,总页数:2") {
		t.Errorf("缺少并发解析日志，实际日志:\n%s", got)
	}
	if !strings.Contains(got, "◇目录总数:4") {
		t.Errorf("目录总数应为 4，实际日志:\n%s", got)
	}
}
