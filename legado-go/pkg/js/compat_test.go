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
