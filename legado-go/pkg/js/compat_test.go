package js

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/dop251/goja"
	"github.com/legado/legado-go/pkg/model"
)

// 这一组对应 2026-10-29 书源核对里 JS 侧的四条差异：
//   - element.text()/ownText() 没做 jsoup 的空白归一化
//   - java.get(url, headers) 被同名的「取变量」版本覆盖
//   - java.ajaxAll 返回裸字符串数组，书源的 `it.body` 拿到 undefined
//   - goja 超时后 runtime 没清中断标记就回池，整池 JS 从此失效

type mapVarStore map[string]string

func (m mapVarStore) Put(k, v string) string { m[k] = v; return v }
func (m mapVarStore) Get(k string) string    { return m[k] }

func TestElementTextNormalized(t *testing.T) {
	doc := parseNode(t, `<html><body><div id="d"> A1 <span>B2</span></div></body></html>`)
	b := &Bindings{Result: NewElementWrap(doc)}
	cases := []struct{ js, want string }{
		{`result.select('#d').text()`, "A1 B2"},
		{`result.select('#d').first().text()`, "A1 B2"},
		{`result.select('#d').first().ownText()`, "A1"},
	}
	for _, c := range cases {
		v, err := DefaultEngine().Eval(c.js, b)
		if err != nil {
			t.Fatalf("%s 执行出错: %v", c.js, err)
		}
		if got := fmt.Sprint(v); got != c.want {
			t.Errorf("%s 应为 %q，实际 %q", c.js, c.want, got)
		}
	}
}

func TestJavaGetOverloads(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "HTTP-BODY:"+r.URL.Path)
	}))
	t.Cleanup(srv.Close)

	b := &Bindings{Vars: mapVarStore{"k": "变量值"}}
	// 1 参：取变量
	v, err := DefaultEngine().Eval(`java.get('k')`, b)
	if err != nil {
		t.Fatalf("java.get('k') 出错: %v", err)
	}
	if got := fmt.Sprint(v); got != "变量值" {
		t.Fatalf("单参应为取变量，实际 %q", got)
	}
	// 2 参：发 HTTP GET
	v, err = DefaultEngine().Eval(`java.get('`+srv.URL+`/x', {'User-Agent':'t'})`, b)
	if err != nil {
		t.Fatalf("java.get(url, headers) 出错: %v", err)
	}
	if got := fmt.Sprint(v); got != "HTTP-BODY:/x" {
		t.Fatalf("双参应为 HTTP GET，实际 %q", got)
	}
}

func TestJavaAjaxAllReturnsStrResponse(t *testing.T) {
	old := Hooks.AjaxAll
	Hooks.AjaxAll = func(src *model.BookSource, urls []string) []*ConnectResult {
		out := make([]*ConnectResult, 0, len(urls))
		for i, u := range urls {
			out = append(out, &ConnectResult{URL: u, Body: fmt.Sprintf("B%d", i), Code: 200})
		}
		return out
	}
	defer func() { Hooks.AjaxAll = old }()

	v, err := DefaultEngine().Eval(`java.ajaxAll(['u1','u2']).map(it => it.body).join(',')`, &Bindings{})
	if err != nil {
		t.Fatalf("ajaxAll 出错: %v", err)
	}
	if got := fmt.Sprint(v); got != "B0,B1" {
		t.Fatalf("ajaxAll 元素应带 body 字段，实际 %q", got)
	}
}

func TestGIntAccumulates(t *testing.T) {
	gInt := 0
	b := &Bindings{GInt: &gInt}
	for i := 0; i < 3; i++ {
		if _, err := DefaultEngine().Eval(`gInt = gInt + 2; ""`, b); err != nil {
			t.Fatalf("执行出错: %v", err)
		}
	}
	if gInt != 6 {
		t.Fatalf("gInt 应跨次累加为 6，实际 %d", gInt)
	}
}

// preUpdateJs 专用的 java.reGetBook / java.refreshTocUrl 在其它阶段必须报错
func TestReGetBookOnlyInPreUpdateJs(t *testing.T) {
	if _, err := DefaultEngine().Eval(`java.reGetBook()`, &Bindings{}); err == nil {
		t.Fatalf("非 preUpdateJs 阶段调用 reGetBook 应报错")
	}
	if _, err := DefaultEngine().Eval(`java.refreshTocUrl()`, &Bindings{InPreUpdateJs: true}); err != nil {
		t.Fatalf("preUpdateJs 阶段且无 hook 时不应报错: %v", err)
	}
}

// 超时被中断过的 runtime 回池前必须 ClearInterrupt，否则该池后续 JS 全部失败
func TestInterruptClearedBeforeReuse(t *testing.T) {
	e := &Engine{
		pools:    map[string]*sync.Pool{},
		libProg:  map[string]*goja.Program{},
		scripts:  map[string]*goja.Program{},
		MaxCache: 16,
		Timeout:  50 * time.Millisecond,
	}
	if _, err := e.Eval(`while(true){}`, &Bindings{}); err == nil {
		t.Fatalf("死循环应超时")
	}
	v, err := e.Eval(`1+1`, &Bindings{})
	if err != nil {
		t.Fatalf("超时后的 runtime 应可复用，实际报错: %v", err)
	}
	if got := fmt.Sprint(v); got != "2" {
		t.Fatalf("复用后结果错误: %q", got)
	}
}

// TestJavaGetStringEvaluatesRule 钉住 `java.getString(rule)` 的语义：
// 它是**按规则求值**（Kotlin JsExtensions.getString → analyzeRule.getString），
// 不是读变量。曾经实现成 Vars.Get，导致
// `a=java.getString('model.lines')` 恒为空，纯 API 书源正文全空。
func TestJavaGetStringEvaluatesRule(t *testing.T) {
	var asked []string
	b := &Bindings{
		Vars: mapVarStore{"model.lines": "不该被当成变量读出来"},
		EvalRuleString: func(rule string) string {
			asked = append(asked, rule)
			if rule == "model.lines" {
				return "第一段正文。"
			}
			return ""
		},
		EvalRuleStringList: func(rule string) []string {
			if rule == "list" {
				return []string{"甲", "乙"}
			}
			return nil
		},
	}

	v, err := DefaultEngine().Eval(`java.getString('model.lines')`, b)
	if err != nil {
		t.Fatalf("java.getString 出错: %v", err)
	}
	if got := fmt.Sprint(v); got != "第一段正文。" {
		t.Fatalf("java.getString 应按规则求值，实际 %q", got)
	}
	if len(asked) != 1 || asked[0] != "model.lines" {
		t.Fatalf("规则串未透传给求值钩子: %v", asked)
	}

	v, err = DefaultEngine().Eval(`java.getStringList('list').join('|')`, b)
	if err != nil {
		t.Fatalf("java.getStringList 出错: %v", err)
	}
	if got := fmt.Sprint(v); got != "甲|乙" {
		t.Fatalf("java.getStringList 结果错误: %q", got)
	}
}

// 书源过 Cloudflare 时普遍用 `java.startBrowserAwait(url,'验证').body()` 取正文
// （如「顶点小说」：`res = java.startBrowserAwait(u,'ver'); java.setContent(res.body())`）。
// Kotlin 的 StrResponse 同时有 body 属性和 body() 方法，goja 一个键只能放一个值，
// 这里钉住"可调用 + 能字符串化"两条，避免改成普通属性后书源报
// `res.body is not a function`。
func TestJavaStartBrowserAwaitReturnsStrResponse(t *testing.T) {
	var gotURL, gotTitle string
	var gotRefetch bool
	b := &Bindings{
		StartBrowser: func(src *model.BookSource, url, title string, refetch bool) (string, int) {
			gotURL, gotTitle, gotRefetch = url, title, refetch
			return "<html>验证后的正文</html>", 200
		},
	}

	v, err := DefaultEngine().Eval(`(function(){
		var r = java.startBrowserAwait('http://site/book/1','请完成验证');
		return r.body() + '|' + r.url + '|' + r.code + '|' + ('' + r.body);
	})()`, b)
	if err != nil {
		t.Fatalf("startBrowserAwait 出错: %v", err)
	}
	want := "<html>验证后的正文</html>|http://site/book/1|200|<html>验证后的正文</html>"
	if got := fmt.Sprint(v); got != want {
		t.Fatalf("返回对象不符合 StrResponse 语义:\n got=%q\nwant=%q", got, want)
	}
	if gotURL != "http://site/book/1" || gotTitle != "请完成验证" || !gotRefetch {
		t.Fatalf("透传给宿主的参数不对: url=%q title=%q refetch=%v", gotURL, gotTitle, gotRefetch)
	}

	// 第三个参数显式 false：直接用浏览器渲染的 HTML，不重新请求
	_, err = DefaultEngine().Eval(`java.startBrowserAwait('http://site/2','t',false)`, b)
	if err != nil {
		t.Fatalf("startBrowserAwait 三个参数时出错: %v", err)
	}
	if gotRefetch {
		t.Fatal("第三个参数为 false 时不应重新取正文")
	}
}

// 宿主不支持内置浏览器时，startBrowserAwait 必须返回空响应而不是抛错，
// 否则书源会在 JS 层直接中断，用户只看到"解析失败"。
func TestJavaStartBrowserAwaitWithoutHost(t *testing.T) {
	v, err := DefaultEngine().Eval(`java.startBrowserAwait('http://x','t').body()`, &Bindings{})
	if err != nil {
		t.Fatalf("无宿主时不应抛错: %v", err)
	}
	if got := fmt.Sprint(v); got != "" {
		t.Fatalf("无宿主时应返回空正文，实际 %q", got)
	}
}
