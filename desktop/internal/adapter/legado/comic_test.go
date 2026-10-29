package legado

import (
	"testing"

	legadomodel "github.com/legado/legado-go/pkg/model"
)

// 漫画源的正文是一串 <img>，阅读器要的是结构化地址。
func TestExtractImages(t *testing.T) {
	cases := []struct {
		name string
		html string
		base string
		want []string
	}{
		{
			name: "绝对地址",
			html: `<img src="https://cdn.example.com/a/1.jpg"><img src="https://cdn.example.com/a/2.jpg">`,
			want: []string{"https://cdn.example.com/a/1.jpg", "https://cdn.example.com/a/2.jpg"},
		},
		{
			name: "相对地址按章节页补全",
			html: `<img src="/img/1.jpg"><img src="2.jpg">`,
			base: "https://manwame.com/book/demo/1.html",
			want: []string{"https://manwame.com/img/1.jpg", "https://manwame.com/book/demo/2.jpg"},
		},
		{
			name: "协议相对地址",
			html: `<img src="//cdn.example.com/x.jpg">`,
			base: "https://manwame.com/book/demo/1.html",
			want: []string{"https://cdn.example.com/x.jpg"},
		},
		{
			name: "忽略 data URI 与重复项",
			html: `<img src="data:image/png;base64,AAA"><img src="https://a.com/1.jpg"><img src="https://a.com/1.jpg">`,
			want: []string{"https://a.com/1.jpg"},
		},
		{
			name: "没有图片",
			html: `<div class="error">未找到 params</div>`,
			want: nil,
		},
		{
			name: "空正文",
			html: "   ",
			want: nil,
		},
	}
	for _, c := range cases {
		got := extractImages(c.html, c.base)
		if len(got) != len(c.want) {
			t.Fatalf("%s: 数量不符 实际 %v 期望 %v", c.name, got, c.want)
		}
		for i := range got {
			if got[i] != c.want[i] {
				t.Fatalf("%s: 第 %d 项 %q，期望 %q", c.name, i, got[i], c.want[i])
			}
		}
	}
}

func TestIsComicSource(t *testing.T) {
	if isComicSource(nil) {
		t.Fatal("nil 不应判定为漫画源")
	}
	if !isComicSource(&legadomodel.BookSource{BookSourceType: 2}) {
		t.Fatal("bookSourceType=2 应判定为漫画源")
	}
	if isComicSource(&legadomodel.BookSource{BookSourceType: 0}) {
		t.Fatal("bookSourceType=0 不应判定为漫画源")
	}
}
