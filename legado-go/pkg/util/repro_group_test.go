package util

import (
	"errors"
	"testing"

	"golang.org/x/net/html"
)

// 回归：分组选择器里混入一个 cascadia 无法解析的子选择器（jsoup 能宽容处理，
// legado 书源里真实存在，如 ESJ Zone 的
// `div.forum-content.mt-3,div[class =d_post_content j_d_post_content]`），
// 不能让整条规则静默返回 0 个节点。
//
// 现在 `[class =a b]` 这种「裸值带空格/数字/斜杠」的写法会在编译前补引号，
// 与 jsoup 的解析结果一致（整串作为一个值做全等匹配），因此不再报错；
// 仍然要保证真正非法的分组被上报、且不牵连合法分组。
func TestSelectGroupToleratesBadSelector(t *testing.T) {
	doc := parse(t, `<html><body>
	  <div class="forum-content mt-3"><p>正文A</p><p>正文B</p></div>
	  <div class="other">别的</div>
	</body></html>`)

	var reported []string
	OnSelectorError = func(sel string, err error) {
		reported = append(reported, sel)
	}
	defer func() { OnSelectorError = nil }()

	got := SelectAll([]*html.Node{doc}, `div.forum-content.mt-3,div[class =d_post_content j_d_post_content]`)
	if len(got) != 1 {
		t.Fatalf("合法分组应命中 1 个节点，实际 %d", len(got))
	}
	if NodeAttr(got[0], "class") != "forum-content mt-3" {
		t.Fatalf("命中节点不对: %v", NodeAttr(got[0], "class"))
	}
	// 裸值补引号后是合法选择器，不应再上报错误
	if len(reported) != 0 {
		t.Fatalf("jsoup 兼容写法不应上报错误，实际 %v", reported)
	}

	// 真正非法的分组仍要上报，且不影响合法分组
	reported = nil
	got = SelectAll([]*html.Node{doc}, `div.other,div::bogus`)
	if len(got) != 1 || NodeAttr(got[0], "class") != "other" {
		t.Fatalf("非法分组不应牵连合法分组，实际 %d", len(got))
	}
	if len(reported) != 1 {
		t.Fatalf("非法分组应上报 1 次，实际 %d: %v", len(reported), reported)
	}
}

func TestSplitSelectorGroup(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"div.a,div.b", []string{"div.a", "div.b"}},
		{`div[class="a,b"],p`, []string{`div[class="a,b"]`, "p"}},
		{"div:not(.a,.b) > p", []string{"div:not(.a,.b) > p"}},
		{`a[href$=","]`, []string{`a[href$=","]`}},
		{"  p  ", []string{"p"}},
	}
	for _, c := range cases {
		got := SplitSelectorGroup(c.in)
		if len(got) != len(c.want) {
			t.Fatalf("%q: 期望 %v，实际 %v", c.in, c.want, got)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("%q: 第 %d 组期望 %q，实际 %q", c.in, i, c.want[i], got[i])
			}
		}
	}
}

// 分组 + 尾部 jsoup 伪类：伪类只作用于逗号前那一个选择器（jsoup 语义）
func TestSelectGroupWithPseudo(t *testing.T) {
	doc := parse(t, `<html><body>
	  <div class="a">1</div><div class="b">2</div><div class="c">3</div>
	</body></html>`)
	got := SelectAll([]*html.Node{doc}, `.a,.b:first`)
	var texts []string
	for _, n := range got {
		texts = append(texts, NodeText(n))
	}
	if len(texts) != 2 || texts[0] != "1" || texts[1] != "2" {
		t.Fatalf("期望 [1 2]，实际 %v", texts)
	}
}

func TestSelectorErrorNilSafe(t *testing.T) {
	OnSelectorError = nil
	doc := parse(t, `<html><body><div class="a">1</div></body></html>`)
	got := SelectAll([]*html.Node{doc}, `div[class =a b]`)
	if len(got) != 0 {
		t.Fatalf("非法选择器应返回空，实际 %d", len(got))
	}
	_ = errors.New("keep import")
}
