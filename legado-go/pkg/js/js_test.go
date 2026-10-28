package js

import (
	"fmt"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

func parseNode(t *testing.T, s string) *html.Node {
	t.Helper()
	n, err := html.Parse(strings.NewReader(s))
	if err != nil {
		t.Fatalf("解析 HTML 失败: %v", err)
	}
	return n
}

func valStr(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	default:
		return fmt.Sprint(x)
	}
}

// JS 里的 select() 必须返回「类 jsoup Elements」：既能当数组用，
// 又要有 text()/attr()/size()/get() —— 书源大量使用 `result.select('x').text()`。
func TestElementsObject(t *testing.T) {
	doc := parseNode(t, `<html><body>
	<div class="box"><a id="t1" href="/1">甲</a><a id="t2" href="/2">乙</a></div>
	<div class="box"><a id="t3" href="/3">丙</a></div>
	</body></html>`)
	b := &Bindings{Result: NewElementWrap(doc)}

	cases := []struct{ js, want string }{
		{`result.select('div.box').size()`, "2"},
		{`result.select('a').size()`, "3"},
		{`result.select('a').text()`, "甲 乙 丙"},
		{`result.select('a').attr('href')`, "/1"},
		{`result.select('a').get(1).text()`, "乙"},
		{`result.select('a')[1].text()`, "乙"},
		{`result.select('a').first().text()`, "甲"},
		{`result.select('a').last().text()`, "丙"},
		{`result.select('a').attr('id')`, "t1"},
		{`result.select('a').get(0).attr('id')`, "t1"},
		{`result.select('.none').size()`, "0"},
		{`result.select('.none').text()`, ""},
		// 单个元素对象同样要有 select/text/attr
		{`result.select('div.box').get(0).select('a').size()`, "2"},
		// 链式：Elements → 元素 → 属性
		{`result.select('div.box').get(0).select('a').attr('href')`, "/1"},
	}
	for _, c := range cases {
		v, err := DefaultEngine().Eval(c.js, b)
		if err != nil {
			t.Errorf("%s 执行失败: %v", c.js, err)
			continue
		}
		if got := valStr(v); got != c.want {
			t.Errorf("%s = %q, 期望 %q", c.js, got, c.want)
		}
	}
}

// select() 的结果导出成 Go 值时应是普通切片（供 analyzeBookList 遍历）
func TestElementsExportIsSlice(t *testing.T) {
	doc := parseNode(t, `<html><body><a href="/1">甲</a><a href="/2">乙</a></body></html>`)
	v, err := DefaultEngine().Eval(`result.select('a')`, &Bindings{Result: NewElementWrap(doc)})
	if err != nil {
		t.Fatalf("执行失败: %v", err)
	}
	list, ok := v.([]any)
	if !ok {
		t.Fatalf("期望导出为 []any，实际 %T", v)
	}
	if len(list) != 2 {
		t.Fatalf("长度错误: %d", len(list))
	}
}

func TestEvalBasics(t *testing.T) {
	if v, err := DefaultEngine().Eval(`[1,2,3].map(x=>x*2).join(",")`, nil); err != nil || v != "2,4,6" {
		t.Fatalf("数组表达式错误: v=%v err=%v", v, err)
	}
	if v, err := DefaultEngine().Eval(`({a:1}).a`, nil); err != nil || valStr(v) != "1" {
		t.Fatalf("对象表达式错误: v=%#v err=%v", v, err)
	}
	if v, err := DefaultEngine().Eval(`null`, nil); err != nil || v != nil {
		t.Fatalf("null 应导出为 nil: v=%#v err=%v", v, err)
	}
	if _, err := DefaultEngine().Eval(`var =`, nil); err == nil {
		t.Fatal("语法错误应报错")
	}
}
