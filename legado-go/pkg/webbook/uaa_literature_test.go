package webbook_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
	. "github.com/legado/legado-go/pkg/webbook"
)

// UAA·文学（纯 API 源）回归。
//
// 线上 api.uaa.com 在沙箱不可达，这里用 mock 还原它的真实响应形状
// （由同站其他书源的 `$.model.data` / `$.model.menus..children.*` 反推）：
//
//	列表：{"model":{"data":[book...]}}
//	详情：{"model":{book}}
//	目录：{"model":{"menus":[{"title":"卷","type":"2","children":[{章}...]}]}}
//
// 该源用 `.[?(@.title)]` 一条规则同时捞书和章节，靠的是递归下降过滤；
// 一旦引擎不认这种写法，列表规则命中 0 条，会静默退化成「按详情页解析」，
// 把列表接口地址当成详情地址 → 能出列表、点进去「书籍信息获取失败」。

const uaaBook = `{
  "id": 1001,
  "title": "测试之书",
  "authors": "某作者",
  "coverUrl": "/cover/1001.jpg",
  "brief": "这是简介。",
  "categories": "都市,校园",
  "finished": 0,
  "pornRateDesc": "中肉(2)",
  "wordCount": 12345,
  "latestUpdate": "2024-05-06 12:00:00",
  "personDesc": "第三人称",
  "orientationDesc": "直男",
  "lengthTypeDesc": "长篇"
}`

const uaaSourceJSON = `[{
  "bookSourceName": "UAA文学mock",
  "bookSourceUrl": "https://api.uaa.com",
  "bookSourceType": 0,
  "enabled": true,
  "enabledExplore": true,
  "exploreUrl": "[{'title':'全部','url':'https://api.uaa.com/novel/app/novel/search?page={{page}}&size=10'}]",
  "searchUrl": "https://api.uaa.com/novel/app/novel/search?keyword={{key}}&page={{page}}&size=10",
  "ruleSearch": {
    "bookList": ".[?(@.title)]",
    "name": "title",
    "author": "authors",
    "bookUrl": "/novel/app/novel/intro?id={{$.id}}",
    "coverUrl": "coverUrl",
    "intro": "brief",
    "wordCount": "wordCount"
  },
  "ruleBookInfo": {
    "init": "model",
    "name": "title",
    "author": "authors",
    "coverUrl": "coverUrl",
    "intro": "{{$.brief}}",
    "kind": "{{java.getString('finished')==0?'连载':'完结'}},{{$.pornRateDesc##\\((.*)\\)##$1###}},{{$.categories}}",
    "lastChapter": "latestUpdate",
    "wordCount": "wordCount",
    "tocUrl": "/novel/app/novel/catalog/{{$.id}}"
  },
  "ruleToc": {
    "chapterList": ".[?(@.title)]",
    "chapterName": "title",
    "chapterUrl": "@js:$=result;(($.type=='2'))?'':'/novel/app/novel/chapter?id='+$.id+'&viewId=1'",
    "isVolume": "@js:{{$.type}}=='2'?true:false;"
  }
}]`

func uaaMockServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(r.URL.Path, "/search"):
			fmt.Fprintf(w, `{"code":200,"model":{"data":[%s],"total":1}}`, uaaBook)
		case strings.Contains(r.URL.Path, "/intro"):
			fmt.Fprintf(w, `{"code":200,"model":%s}`, uaaBook)
		case strings.Contains(r.URL.Path, "/catalog/"):
			fmt.Fprint(w, `{"code":200,"model":{"menus":[
				{"title":"第一卷","type":"2","children":[
					{"id":11,"title":"第一章 起","type":"1","onlineTime":"2024-05-01T10:00:00.000","volumeNum":3200},
					{"id":12,"title":"第二章 承","type":"1","onlineTime":"2024-05-02T11:00:00.000","volumeNum":4100}
				]}
			]}}`)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

func loadUAASourceJSON(t *testing.T, mockURL string) *model.BookSource {
	t.Helper()
	list, err := source.ParseBytes([]byte(strings.ReplaceAll(uaaSourceJSON, "https://api.uaa.com", mockURL)))
	if err != nil || len(list) == 0 {
		t.Fatalf("解析书源失败: %v", err)
	}
	return list[0]
}

// TestUAALiteratureDetail 复现“发现页有列表、点详情获取失败”。
// 关键断言是 bookUrl：它必须是详情接口，而不是列表接口地址。
func TestUAALiteratureDetail(t *testing.T) {
	srv := uaaMockServer(t)
	src := loadUAASourceJSON(t, srv.URL)

	list, err := ExploreBook(src, "", 1)
	if err != nil {
		t.Fatalf("发现列表失败: %v", err)
	}
	if len(list) != 1 {
		t.Fatalf("列表应命中 1 本，实际 %d", len(list))
	}
	b := list[0]
	if b.Name != "测试之书" {
		t.Errorf("书名错误: %q", b.Name)
	}
	wantURL := srv.URL + "/novel/app/novel/intro?id=1001"
	if b.BookUrl != wantURL {
		t.Fatalf("bookUrl 应为详情接口 %q，实际 %q（说明列表规则没命中，走了详情页兜底）", wantURL, b.BookUrl)
	}

	// 用 model.NewBook()：它会初始化变量容器，规则里的 java.getString 依赖它
	// （裸 &model.Book{} 的容器为 nil，读取变量会 panic）。
	book := model.NewBook()
	book.BookUrl, book.Name, book.Author = b.BookUrl, b.Name, b.Author
	book.Origin, book.Type = src.BookSourceUrl, b.Type
	if b.Variable != "" {
		book.LoadJSON(b.Variable)
	}
	if err := GetBookInfo(src, book); err != nil {
		t.Fatalf("获取书籍详情失败: %v", err)
	}
	if book.Name != "测试之书" {
		t.Errorf("详情书名错误: %q", book.Name)
	}
	if book.CoverUrl != srv.URL+"/cover/1001.jpg" {
		t.Errorf("封面地址错误: %q", book.CoverUrl)
	}
	if !strings.Contains(book.Kind, "连载") {
		t.Errorf("分类应含连载: %q", book.Kind)
	}
	if book.TocUrl != srv.URL+"/novel/app/novel/catalog/1001" {
		t.Errorf("目录地址错误: %q", book.TocUrl)
	}

	chs, err := GetChapterList(src, book, false)
	if err != nil {
		t.Fatalf("获取目录失败: %v", err)
	}
	var names []string
	for _, c := range chs {
		names = append(names, c.Title)
	}
	joined := strings.Join(names, "|")
	if !strings.Contains(joined, "第一章 起") || !strings.Contains(joined, "第二章 承") {
		t.Fatalf("目录应包含两章，实际 %q", joined)
	}
	for _, c := range chs {
		if c.Title == "第一章 起" && !strings.Contains(c.Url, "/novel/app/novel/chapter?id=11") {
			t.Errorf("章节地址错误: %q", c.Url)
		}
	}
}
