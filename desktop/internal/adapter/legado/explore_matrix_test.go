package legado

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	legadomodel "github.com/legado/legado-go/pkg/model"

	"github.com/legado/desktop/internal/domain"
)

// 形态矩阵回归：对应《桌面端解析复查计划.md》P2 的 M1~M9。
//
// 背景：桌面端曾因 `paged` 判定只认字面量 {{page}} 而漏掉 {{page-1}}，
// 导致超星源发现页「不支持翻页」。本文件把宿主层所有「决定请求行为」的
// 路径按真实书源形态各跑一遍，防止同类回归。
//
// M4（loginUrl 三形态）/ M5（登录头三态输入）由 login_test.go 与
// internal/domain/login_header_test.go 覆盖，此处不重复。

// recordingServer 记录收到的请求路径与 POST 表单，供断言页码链路。
type recordingServer struct {
	*httptest.Server
	mu     sync.Mutex
	paths  []string
	starts []string // POST body 里的 start 值
}

func newRecordingServer(handler http.HandlerFunc) *recordingServer {
	rs := &recordingServer{}
	rs.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rs.mu.Lock()
		rs.paths = append(rs.paths, r.URL.Path)
		_ = r.ParseForm()
		rs.starts = append(rs.starts, r.PostFormValue("start"))
		rs.mu.Unlock()
		handler(w, r)
	}))
	return rs
}

func (rs *recordingServer) snapshot() (paths, starts []string) {
	rs.mu.Lock()
	defer rs.mu.Unlock()
	return append([]string(nil), rs.paths...), append([]string(nil), rs.starts...)
}

func matrixSource(t *testing.T, base, exploreURL, ruleExplore string) *domain.BookSource {
	t.Helper()
	raw := fmt.Sprintf(`{
		"bookSourceUrl": %q,
		"bookSourceName": "矩阵测试源",
		"bookSourceType": 0,
		"enabledExplore": true,
		"exploreUrl": %s,
		"ruleExplore": %s
	}`, base, jsonString(t, exploreURL), ruleExplore)
	return &domain.BookSource{Name: "矩阵测试源", URL: base, Raw: raw, Enabled: true}
}

// jsonString 把 Go 字符串编成 JSON 字符串字面量（含转义），嵌进 raw。
func jsonString(t *testing.T, s string) string {
	t.Helper()
	b, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("jsonString: %v", err)
	}
	return string(b)
}

func names(list []*domain.SearchResult) []string {
	out := make([]string, 0, len(list))
	for _, b := range list {
		out = append(out, b.Name)
	}
	return out
}

func fetchExplorePage(t *testing.T, f *Fetcher, src *domain.BookSource, kindURL string, page int) []*domain.SearchResult {
	t.Helper()
	list, err := f.Explore(context.Background(), src, kindURL, page)
	if err != nil {
		t.Fatalf("发现第 %d 页失败: %v", page, err)
	}
	return list
}

// M1 {{page}} HTML 翻页：第 2 页请求 /list-2.html，书与第 1 页不同。
func TestMatrixM1_HTMLEscapePage(t *testing.T) {
	srv := newRecordingServer(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		switch r.URL.Path {
		case "/list-1.html":
			fmt.Fprint(w, `<html><body><div class="item"><h3>甲</h3><a href="/b/1.html">1</a></div><div class="item"><h3>乙</h3><a href="/b/2.html">2</a></div></body></html>`)
		case "/list-2.html":
			fmt.Fprint(w, `<html><body><div class="item"><h3>丙</h3><a href="/b/3.html">3</a></div><div class="item"><h3>丁</h3><a href="/b/4.html">4</a></div></body></html>`)
		default:
			http.NotFound(w, r)
		}
	})
	defer srv.Close()

	src := matrixSource(t, srv.URL, "/list-{{page}}.html",
		`{"bookList":"div.item","name":"h3@text","bookUrl":"a@href"}`)
	f := NewFetcher("matrix-test")

	p1 := names(fetchExplorePage(t, f, src, "/list-{{page}}.html", 1))
	p2 := names(fetchExplorePage(t, f, src, "/list-{{page}}.html", 2))
	if len(p1) != 2 || len(p2) != 2 {
		t.Fatalf("每页应有 2 本书: p1=%v p2=%v", p1, p2)
	}
	if p1[0] != "甲" || p2[0] != "丙" {
		t.Fatalf("第 2 页应返回不同书籍: p1=%v p2=%v", p1, p2)
	}
	paths, _ := srv.snapshot()
	if len(paths) != 2 || paths[0] != "/list-1.html" || paths[1] != "/list-2.html" {
		t.Fatalf("请求路径链路错误: %v", paths)
	}
}

// M2 {{page-1}} POST JSON（超星形态，本类 bug 的原始形态）：
// 引擎页码从 1 开始递增（Kotlin ExploreShowViewModel.kt:32 `page = 1`），
// 偏移翻页必须写 {{(page-1)*size}}。写成 {{page-1}} 会在第 2 页发出
// start=1，与第 1 页重叠——这是矩阵测试抓到的真实书源 bug。
func TestMatrixM2_PostJSONPageMinusOne(t *testing.T) {
	srv := newRecordingServer(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method", http.StatusMethodNotAllowed)
			return
		}
		start := r.PostFormValue("start")
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"subject":[{"name":"S%s-甲","bookUrl":"/b/%s/1"},{"name":"S%s-乙","bookUrl":"/b/%s/2"}]}`,
			start, start, start, start)
	})
	defer srv.Close()

	src := matrixSource(t, srv.URL,
		`/getBook,{"method":"POST","body":"start={{(page-1)*25}}&size=25"}`,
		`{"bookList":"subject","name":"name","bookUrl":"bookUrl"}`)
	f := NewFetcher("matrix-test")
	kindURL := "/getBook,{\"method\":\"POST\",\"body\":\"start={{(page-1)*25}}&size=25\"}"

	p1 := names(fetchExplorePage(t, f, src, kindURL, 1))
	p2 := names(fetchExplorePage(t, f, src, kindURL, 2))
	if len(p1) != 2 || len(p2) != 2 {
		t.Fatalf("每页应有 2 本书: p1=%v p2=%v", p1, p2)
	}
	if p1[0] != "S0-甲" || p2[0] != "S25-甲" {
		t.Fatalf("{{page-1}} 求值错误: p1=%v p2=%v", p1, p2)
	}
	_, starts := srv.snapshot()
	if len(starts) != 2 || starts[0] != "0" || starts[1] != "25" {
		t.Fatalf("start 序列应为 [0 25]: %v", starts)
	}
}

// M3 <1,2,3> 页码列表：第 2 页按列表下标取 /sort/2.html。
func TestMatrixM3_PageList(t *testing.T) {
	srv := newRecordingServer(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		switch r.URL.Path {
		case "/sort/1.html":
			fmt.Fprint(w, `<html><body><div class="item"><h3>壹</h3><a href="/b/1.html">1</a></div></body></html>`)
		case "/sort/2.html":
			fmt.Fprint(w, `<html><body><div class="item"><h3>贰</h3><a href="/b/2.html">2</a></div></body></html>`)
		default:
			http.NotFound(w, r)
		}
	})
	defer srv.Close()

	src := matrixSource(t, srv.URL, "/sort/<1,2,3>.html",
		`{"bookList":"div.item","name":"h3@text","bookUrl":"a@href"}`)
	f := NewFetcher("matrix-test")

	p1 := names(fetchExplorePage(t, f, src, "/sort/<1,2,3>.html", 1))
	p2 := names(fetchExplorePage(t, f, src, "/sort/<1,2,3>.html", 2))
	if len(p1) != 1 || len(p2) != 1 || p1[0] != "壹" || p2[0] != "贰" {
		t.Fatalf("<1,2,3> 页码列表翻页错误: p1=%v p2=%v", p1, p2)
	}
}

// M6 纯发现源（无 searchUrl）：HasExplore=true 且分类可解析。
func TestMatrixM6_PureExploreSource(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()

	src := matrixSource(t, srv.URL, "全部::/all.html",
		`{"bookList":"div.item","name":"h3@text","bookUrl":"a@href"}`)
	f := NewFetcher("matrix-test")

	if !f.HasExplore(src) {
		t.Fatal("纯发现源应 HasExplore=true")
	}
	kinds, err := f.ExploreKinds(context.Background(), src)
	if err != nil || len(kinds) != 1 || kinds[0].Title != "全部" {
		t.Fatalf("分类解析错误: kinds=%#v err=%v", kinds, err)
	}
}

// M7 enabledExplore=false：不出现在发现页（HasExplore=false、分类为空）。
func TestMatrixM7_ExploreDisabled(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()

	src := matrixSource(t, srv.URL, "/all.html",
		`{"bookList":"div.item","name":"h3@text","bookUrl":"a@href"}`)
	raw := strings.Replace(src.Raw, `"enabledExplore": true`, `"enabledExplore": false`, 1)
	src.Raw = raw
	f := NewFetcher("matrix-test")

	if f.HasExplore(src) {
		t.Fatal("enabledExplore=false 应 HasExplore=false")
	}
	kinds, err := f.ExploreKinds(context.Background(), src)
	if err != nil || len(kinds) != 0 {
		t.Fatalf("enabledExplore=false 分类应为空: kinds=%#v err=%v", kinds, err)
	}
}

// M9 <js> exploreUrl：脚本求值后解析出分类（超星形态）。
func TestMatrixM9_JsExploreUrl(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.NotFound(w, r)
	}))
	defer srv.Close()

	js := `<js>
list=[["A","/a.html"],["B","/b.html"]];
list.map(a=>a[0]+"::/x"+a[1]).join("&&")
</js>`
	// JS 返回「标题::地址」行，引擎 ParseExploreKinds 负责拆分。
	src := matrixSource(t, srv.URL, js,
		`{"bookList":"div.item","name":"h3@text","bookUrl":"a@href"}`)
	f := NewFetcher("matrix-test")

	kinds, err := f.ExploreKinds(context.Background(), src)
	if err != nil {
		t.Fatalf("ExploreKinds 失败: %v", err)
	}
	if len(kinds) != 2 {
		t.Fatalf("<js> exploreUrl 应解析出 2 个分类: %#v", kinds)
	}
	titles := []string{kinds[0].Title, kinds[1].Title}
	sort.Strings(titles)
	if titles[0] != "A" || titles[1] != "B" {
		t.Fatalf("分类名错误: %#v", kinds)
	}
}

// M8 卷名过滤：与 Kotlin Debug.kt:270 谓词逐字对齐——
// isVolume 且 url 以标题开头才过滤；只有 isVolume 的条目必须保留。
func TestMatrixM8_FilterOutVolumes(t *testing.T) {
	chapters := []*legadomodel.BookChapter{
		{Title: "第一卷", Url: "第一卷0", IsVolume: true},          // 卷名，剔除
		{Title: "第一章", Url: "http://x/c/1", IsVolume: false}, // 正文，保留
		{Title: "第二卷", Url: "http://x/vol2", IsVolume: true}, // IsVolume 但 url 不是标题开头，保留
	}
	toc := filterOutVolumes(chapters)
	if len(toc) != 2 {
		t.Fatalf("应保留 2 条: %#v", toc)
	}
	if toc[0].Title != "第一章" || toc[1].Title != "第二卷" {
		t.Fatalf("过滤结果错误: %#v", toc)
	}
}

// 实源回归：直接加载仓库里的超星书源文件，验证其发现分页公式
// {{(page-1)*25}} 在引擎里求值出 start=0/25（2026-11-01 由 {{page-1}} 修正）。
func TestMatrixM2_ChaoxingShippedSource(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "超星书源_修复版.json"))
	if err != nil {
		t.Skipf("书源文件不存在，跳过: %v", err)
	}
	var list []map[string]any
	if err := json.Unmarshal(raw, &list); err != nil {
		t.Fatalf("书源 JSON 解析失败: %v", err)
	}
	mock := newRecordingServer(func(w http.ResponseWriter, r *http.Request) {
		start := r.PostFormValue("start")
		w.Header().Set("Content-Type", "application/json")
		body := `{"subject":[{"name":"S` + start + `-甲","bookUrl":"/b/` + start + `/1"}]}`
		fmt.Fprint(w, body)
	})
	defer mock.Close()

	b, _ := json.Marshal(list[0])
	text := strings.Replace(string(b), "http://yz4.chaoxing.com", mock.URL, 1)
	src := &domain.BookSource{Name: "超星", URL: mock.URL, Raw: text, Enabled: true}

	f := NewFetcher("matrix-test")
	ks, err := f.ExploreKinds(context.Background(), src)
	if err != nil || len(ks) == 0 {
		t.Fatalf("超星源分类解析失败: n=%d err=%v", len(ks), err)
	}
	p1, err := f.Explore(context.Background(), src, ks[0].URL, 1)
	if err != nil {
		t.Fatalf("第 1 页失败: %v", err)
	}
	p2, err := f.Explore(context.Background(), src, ks[0].URL, 2)
	if err != nil {
		t.Fatalf("第 2 页失败: %v", err)
	}
	if len(p1) == 0 || len(p2) == 0 {
		t.Fatalf("两页都应有书: p1=%d p2=%d", len(p1), len(p2))
	}
	if p1[0].Name == p2[0].Name {
		t.Fatalf("第 2 页与第 1 页重叠（start 求值错误）: %q", p1[0].Name)
	}
	_, starts := mock.snapshot()
	if len(starts) != 2 || starts[0] != "0" || starts[1] != "25" {
		t.Fatalf("超星源 start 序列应为 [0 25]: %v", starts)
	}
}
