package legado

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestParseDebugStage(t *testing.T) {
	cases := []struct {
		in   string
		want debugStage
		ok   bool
	}{
		{"", stageContent, true},
		{"all", stageContent, true},
		{"content", stageContent, true},
		{"search", stageSearch, true},
		{"explore", stageExplore, true},
		{"info", stageInfo, true},
		{"detail", stageInfo, true},
		{"toc", stageTOC, true},
		{"catalog", stageTOC, true},
		{"  TOC  ", stageTOC, true},
		{"unknown", stageContent, false},
	}
	for _, c := range cases {
		got, ok := parseDebugStage(c.in)
		if ok != c.ok {
			t.Fatalf("%q 的可用性判断错了: ok=%v", c.in, ok)
		}
		if got != c.want {
			t.Fatalf("%q 解析成 %v，期望 %v", c.in, got, c.want)
		}
	}
}

func TestTruncateBody_KeepsUTF8(t *testing.T) {
	body := strings.Repeat("中", 100) // 每个 3 字节
	out := truncateBody(body, 4)     // 落在「中」的中间，必须回退到 3

	if !strings.Contains(out, "已截断") {
		t.Fatalf("应当带有截断提示: %q", out)
	}
	head, _, _ := strings.Cut(out, "\n…")
	if !utf8.ValidString(head) {
		t.Fatalf("截断点切出了非法 UTF-8: %q", head)
	}
	if head != "中" {
		t.Fatalf("期望保留 1 个字，实际 %q", head)
	}
}

func TestTruncateBody_ShortBodyUntouched(t *testing.T) {
	if got := truncateBody("short", 100); got != "short" {
		t.Fatalf("未超限的响应体不该被改写: %q", got)
	}
}
