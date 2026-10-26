package util

import (
	"strings"
	"testing"
)

func TestHtmlFormat(t *testing.T) {
	// 对齐 legado HtmlFormatter.format：去标签、块级转换行、段落缩进两个全角空格
	in := `第一段&nbsp;&nbsp;内容<div>第二段<br>换行</div><!-- 注释 --><section>尾巴</section>`
	got := HtmlFormat(in)
	want := "第一段 内容\n　　第二段\n　　换行\n　　尾巴"
	if got != want {
		t.Fatalf("HtmlFormat 结果不符\n got=%q\nwant=%q", got, want)
	}
}

func TestHtmlFormatRemovesImg(t *testing.T) {
	got := HtmlFormat(`<p>文字<img src="https://a.com/1.jpg">结尾</p>`)
	if strings.Contains(got, "<img") || strings.Contains(got, "1.jpg") {
		t.Fatalf("简介格式化应移除 img 标签: %q", got)
	}
	if !strings.Contains(got, "文字") || !strings.Contains(got, "结尾") {
		t.Fatalf("文本内容丢失: %q", got)
	}
}

func TestFormatKeepImg(t *testing.T) {
	// 保留 <img> 并把 data-src / data-* 统一成 src，相对地址补全
	in := `文字<img src="/a.jpg"><img data-src="/b.jpg"><img data-original="/c.jpg">结尾`
	got := FormatKeepImg(in, "https://h.com/dir/")
	want := `文字<img src="https://h.com/a.jpg"><img src="https://h.com/b.jpg"><img src="https://h.com/c.jpg">结尾`
	if got != want {
		t.Fatalf("FormatKeepImg 结果不符\n got=%q\nwant=%q", got, want)
	}
}

func TestFormatKeepImgBlockWrap(t *testing.T) {
	in := `<p>开头</p><img src="/a.jpg"><span>结尾</span>`
	got := FormatKeepImg(in, "https://h.com/")
	// 首行以块级标签开头时，indent1 与 indent2 会叠加成 4 个全角空格（与 legado 一致）
	want := "　　　　开头\n　　<img src=\"https://h.com/a.jpg\">结尾"
	if got != want {
		t.Fatalf("FormatKeepImg 块级处理不符\n got=%q\nwant=%q", got, want)
	}
}

func TestFormatKeepImgRuleSrcWithParam(t *testing.T) {
	// src 里是 {{}} 规则：规则串必须原样保留（不能被百分号转义），
	// URL 选项 `,{...}` 原样拼回地址尾部
	in := `<img src="{{$.pic}},{'headers':{'Referer':'x'}}">`
	got := FormatKeepImg(in, "https://h.com/")
	want := `<img src="https://h.com/{{$.pic}},{'headers':{'Referer':'x'}}">`
	if got != want {
		t.Fatalf("规则 src 处理错误\n got=%q\nwant=%q", got, want)
	}
}
