package rule

import (
	"reflect"
	"testing"
)

// 这一组是 2026-10-29 书源处理核对的回归用例：
// 每一条都对应一个与 Kotlin 原版行为不一致、且**不报错只出错数据**的差异。
// 修改规则层时如果又把它们改回去，这里会直接失败。

const compatHTML = `<html><body>
<ul id="list">
  <li> A1 </li>
  <li>
     B2
  </li>
  <li>C3</li>
  <li>D4</li>
</ul>
<div id="blocks"><div>块一</div><div>块二</div></div>
<div id="own"> 自己 <span>子</span> </div>
<div id="inline">前<span>中</span>后</div>
<a id="q1" href="/1/x" title="2号">一</a>
<a id="q2" href="/2/y" title="T2">二</a>
</body></html>`

func compatRule(t *testing.T, content string) *AnalyzeRule {
	t.Helper()
	ar := New(nil)
	ar.SetContent(content, "https://example.com/")
	ar.SetRedirectUrl("https://example.com/")
	return ar
}

// @text 必须做 jsoup Element.text() 的空白归一化（折叠空白 + trim）
func TestTextNormalization(t *testing.T) {
	ar := compatRule(t, compatHTML)
	got := ar.GetStringList("li@text")
	want := []string{"A1", "B2", "C3", "D4"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("li@text 应为 %#v，实际 %#v", want, got)
	}
	// 块级边界补空格（jsoup 的 div 之间是一个空格）
	if got := ar.GetString("div#blocks@text"); got != "块一 块二" {
		t.Fatalf("块级元素之间应补空格，实际 %q", got)
	}
	// 行内元素之间不补空格
	if got := ar.GetString("div#inline@text"); got != "前中后" {
		t.Fatalf("行内元素不应补空格，实际 %q", got)
	}
	// ownText 只取直接文本子节点，同样归一化
	if got := ar.GetString("div#own@ownText"); got != "自己" {
		t.Fatalf("ownText 归一化错误: %q", got)
	}
}

// [] 多索引必须按书写顺序取，且区间/单值混排也要保序
func TestMultiIndexOrder(t *testing.T) {
	ar := compatRule(t, compatHTML)
	cases := []struct {
		rule string
		want []string
	}{
		{"li[2,0]@text", []string{"C3", "A1"}},
		{"li[0,2]@text", []string{"A1", "C3"}},
		{"li[3,1]@text", []string{"D4", "B2"}},
		{"li[0:1,3]@text", []string{"A1", "B2", "D4"}},
		{"li[-1,0]@text", []string{"D4", "A1"}},
	}
	for _, c := range cases {
		if got := ar.GetStringList(c.rule); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s 应为 %#v，实际 %#v", c.rule, c.want, got)
		}
	}
}

// %% 以第 1 段的长度为界（Kotlin `for (i in results[0].indices)`）
func TestMergePercentBounds(t *testing.T) {
	ar := compatRule(t, compatHTML)
	got := ar.GetStringList("li[0]@text %% li[0,1]@text")
	want := []string{"A1", "A1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("较短的首段不会被拉长，应为 %#v，实际 %#v", want, got)
	}
	got = ar.GetStringList("li[0,1]@text %% li[0]@text")
	want = []string{"A1", "A1", "B2"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("按首段长度 2 截断，应为 %#v，实际 %#v", want, got)
	}
}

// 属性选择器的裸值（数字开头、含 /）要能解析，与 jsoup 一致
func TestAttrSelectorBareValue(t *testing.T) {
	ar := compatRule(t, compatHTML)
	cases := []struct {
		rule string
		want string
	}{
		{`a[href^=/1]@text`, "一"},
		{`a[href$=/2/y]@text`, "二"},
		{`a[title$=2]@text`, "二"},
		{`a[title^=T]@text`, "二"},
		{`a[href*=/2/]@text`, "二"},
	}
	for _, c := range cases {
		if got := ar.GetString(c.rule); got != c.want {
			t.Errorf("%s 应为 %q，实际 %q", c.rule, c.want, got)
		}
	}
}

// getString 对 JS 返回的数组按 Java List.toString() 处理：`[a, b]`
func TestGetStringFromList(t *testing.T) {
	ar := compatRule(t, `<html><body><p>x</p></body></html>`)
	if got := ar.GetString(`@js:[1,2]`); got != "[1, 2]" {
		t.Fatalf("数组应字符串化为 [1, 2]，实际 %q", got)
	}
	if got := ar.GetString(`@js:['a','b']`); got != "[a, b]" {
		t.Fatalf("字符串数组应字符串化为 [a, b]，实际 %q", got)
	}
}

// JSONPath 的聚合函数（ojg 不支持，需自行实现）
func TestJSONPathFunctions(t *testing.T) {
	const data = `{"data":{"list":[10,20,30],"name":"abcd","obj":{"a":1,"b":2}}}`
	ar := compatRule(t, data)
	cases := []struct {
		rule string
		want string
	}{
		{"$.data.list.length()", "3"},
		{"$.data.name.length()", "4"},
		{"$.data.obj.length()", "2"},
		{"$.data.list.min()", "10"},
		{"$.data.list.max()", "30"},
		{"$.data.list.sum()", "60"},
		{"$.data.list.avg()", "20"},
	}
	for _, c := range cases {
		if got := ar.GetString(c.rule); got != c.want {
			t.Errorf("%s 应为 %q，实际 %q", c.rule, c.want, got)
		}
	}
}
