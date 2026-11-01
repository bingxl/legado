package dto

import (
	"testing"

	"github.com/legado/desktop/internal/domain"
)

// 发现分类的 Paged 判定必须覆盖 {{page-1}} 等表达式写法，
// 否则像超星（start={{page-1}}）这类源会被误判为「不支持翻页」。
func TestNewExploreKindView_Paged(t *testing.T) {
	cases := []struct {
		url   string
		paged bool
	}{
		{"/allbook/{{page}}.html", true},
		{"/s,{'method':'POST','body':'start={{page-1}}&size=25'}", true},
		{"{{ page + 1 }}", true},
		{"{{(page-1)*25}}", true}, // 超星公式：{{ 后是括号，不能只认 {{page 前缀
		{"/sort/<1,2,3>.html", true},
		{"/list.html", false},
		{"/api?pageSize=20", false}, // 含 page 字样的自定义变量不算分页
		{"{{pageNumber}}", false},   // 同上
		{"a@page", false},           // 原版引擎无 @page 约定，不应误报
	}
	for _, c := range cases {
		got := NewExploreKindView(domain.ExploreKind{Title: "t", URL: c.url}).Paged
		if got != c.paged {
			t.Errorf("url=%q Paged=%v, want %v", c.url, got, c.paged)
		}
	}
}
