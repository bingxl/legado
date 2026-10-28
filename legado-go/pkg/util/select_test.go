package util

import (
	"strings"
	"testing"

	"golang.org/x/net/html"
)

// 索引伪类作用在「整个结果集」上，顺序为 h,a,b,c
const pseudoHTML = `<ul class="txt-list">
  <li id="h">表头</li>
  <li id="a">甲</li>
  <li id="b">乙</li>
  <li id="c">丙</li>
</ul>
<ul class="txt-list" align="center"><li id="p">分页</li></ul>`

func parse(t *testing.T, s string) *html.Node {
	t.Helper()
	n, err := html.Parse(strings.NewReader(s))
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	return n
}

// 回归：legado 书源常用的 jsoup 索引伪类 :gt/:lt/:eq/:first/:last/:even/:odd，
// cascadia 不支持，必须在这里兜住，否则整条选择器静默返回 0 个节点。
func TestSelectJsoupPseudo(t *testing.T) {
	cases := []struct {
		sel  string
		want string // 期望命中的 id，用逗号分隔
	}{
		{".txt-list:not([align])>li", "h,a,b,c"},
		{".txt-list:not([align])>li:gt(0)", "a,b,c"}, // 跳过表头（书源里最常见的用法）
		{".txt-list:not([align])>li:lt(2)", "h,a"},
		{".txt-list:not([align])>li:eq(1)", "a"},
		{".txt-list:not([align])>li:first", "h"},
		{".txt-list:not([align])>li:last", "c"},
		{".txt-list:not([align])>li:even", "h,b"},
		{".txt-list:not([align])>li:odd", "a,c"},
		{".txt-list:not([align])>li:gt(0):lt(2)", "a,b"}, // 多个伪类按书写顺序依次生效
		{".txt-list>li:first-child", "h,p"},              // 标准伪类不受影响
	}
	root := parse(t, pseudoHTML)
	for _, c := range cases {
		nodes := Select(root, c.sel)
		got := []string{}
		for _, n := range nodes {
			if id := NodeAttr(n, "id"); id != "" {
				got = append(got, id)
			}
		}
		if strings.Join(got, ",") != c.want {
			t.Errorf("%s: 期望 [%s]，实际 [%s]", c.sel, c.want, strings.Join(got, ","))
		}
	}
}

// 自身匹配 + 伪类
func TestSelectWithSelfPseudo(t *testing.T) {
	root := parse(t, pseudoHTML)
	li := Select(root, "#b")
	if len(li) != 1 {
		t.Fatalf("未找到 #b")
	}
	if got := SelectWithSelf(li[0], "li:eq(0)"); len(got) != 1 || got[0] != li[0] {
		t.Errorf("SelectWithSelf 应包含自身: %d", len(got))
	}
}
