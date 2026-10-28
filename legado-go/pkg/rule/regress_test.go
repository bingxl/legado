package rule

import "testing"

// 回归：{{...}} 求值为空串时必须把整段替换掉，而不是保留原样。
// 典型书源写法：`/allbook{{page === 1 ? ” : '_15155_' + page}}.html`
// （狼人小说 exploreUrl），首页要去掉整段，否则请求到 /allbook{{...}}.html → 404。
func TestInnerBraceReplaceEmptyValue(t *testing.T) {
	n := 0
	out, ok := InnerBraceReplace("/allbook{{x}}.html", "{{", 2, 2, func(string) string {
		n++
		return ""
	})
	if !ok {
		t.Fatalf("命中却返回 ok=false")
	}
	if out != "/allbook.html" {
		t.Fatalf("空替换未生效: %q", out)
	}
	if n != 1 {
		t.Fatalf("回调次数错误: %d", n)
	}

	// 未命中时 ok=false，调用方沿用原串
	if out, ok := InnerBraceReplace("/allbook.html", "{{", 2, 2, func(string) string { return "x" }); ok || out != "" {
		t.Fatalf("未命中应返回 (\"\", false)，实际 (%q, %v)", out, ok)
	}

	// 多段：空值与正常值混用
	out, ok = InnerBraceReplace("a{{e}}b{{v}}c", "{{", 2, 2, func(inner string) string {
		if inner == "e" {
			return ""
		}
		return "V"
	})
	if !ok || out != "abVc" {
		t.Fatalf("多段替换错误: (%q, %v)", out, ok)
	}
}

// 回归：单段规则是「属性名」而非选择器（狼人小说 `chapterUrl: "href"`）。
func TestSingleSegmentAttribute(t *testing.T) {
	const html = `<html><body>
<div id="box"><a href="/c/1" title="章节">第一章</a></div>
<span class="text-label">标签文字</span>
</body></html>`
	ar := newTestRule(t, html)

	// 裸属性名 → 取当前元素的属性
	ar.SetContent(ar.GetElements("a")[0])
	if got := ar.GetString("href"); got != "/c/1" {
		t.Fatalf("单段属性名 href 取值错误: %q", got)
	}
	if got := ar.GetString("title"); got != "章节" {
		t.Fatalf("单段属性名 title 取值错误: %q", got)
	}

	// 单段取值关键字仍然是 text
	ar2 := newTestRule(t, html)
	ar2.SetContent(ar2.GetElements("a")[0])
	if got := ar2.GetString("text"); got != "第一章" {
		t.Fatalf("单段 text 取值错误: %q", got)
	}

	// 选择器形态（text./class./tag./含索引）仍按选择器处理
	if got := newTestRule(t, html).GetString("text.标签文字"); got != "标签文字" {
		t.Fatalf("text. 选择器错误: %q", got)
	}
	if got := newTestRule(t, html).GetString("tag.a@href"); got != "/c/1" {
		t.Fatalf("tag. 选择器错误: %q", got)
	}
	if got := newTestRule(t, html).GetString("class.text-label@text"); got != "标签文字" {
		t.Fatalf("class. 选择器错误: %q", got)
	}
}

func TestIsSelectorRule(t *testing.T) {
	cases := map[string]bool{
		"href":       false,
		"title":      false,
		"src":        false,
		"data-src":   false,
		"abs:href":   false,
		"text.最新章节":  true,
		"class.item": true,
		"tag.a":      true,
		"id.foo":     true,
		"children":   true,
		".item":      true,
		"tag.a[0]":   true,
		"a > b":      true,
		"!0":         true,
		"":           false,
		"ownText.第":  true,
	}
	for in, want := range cases {
		if got := isSelectorRule(in); got != want {
			t.Errorf("isSelectorRule(%q)=%v, want %v", in, got, want)
		}
	}
}
