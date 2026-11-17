package legado

import (
	"context"
	"strings"
	"testing"

	"github.com/legado/desktop/internal/domain"
	legadomodel "github.com/legado/legado-go/pkg/model"
)

func TestIsAudioSource(t *testing.T) {
	if isAudioSource(nil) {
		t.Fatal("nil 书源不应判为音频源")
	}
	if !isAudioSource(&legadomodel.BookSource{BookSourceType: sourceTypeAudio}) {
		t.Fatal("bookSourceType=1 应判为音频源")
	}
	if isAudioSource(&legadomodel.BookSource{BookSourceType: sourceTypeText}) {
		t.Fatal("文本源不应判为音频源")
	}
}

func TestNormalizeAudioRule(t *testing.T) {
	cases := []struct{ in, want string }{
		{"  https://cdn.example.com/a.mp3  ", "https://cdn.example.com/a.mp3"},
		{`https://cdn.example.com/a.mp3,{"headers":{"X-Token":"t"}}`, `https://cdn.example.com/a.mp3,{"headers":{"X-Token":"t"}}`},
		{`<audio src="https://cdn.example.com/b.m4a" controls></audio>`, "https://cdn.example.com/b.m4a"},
		{`<source src='https://cdn.example.com/c.aac'>`, "https://cdn.example.com/c.aac"},
		{"", ""},
	}
	for _, c := range cases {
		if got := normalizeAudioRule(c.in); got != c.want {
			t.Errorf("normalizeAudioRule(%q) = %q，期望 %q", c.in, got, c.want)
		}
	}
}

// 音频源最核心的一条：章节正文里的 URL 规则串必须经 AnalyzeUrl 展开，
// 真实地址与自定义请求头都要落到 AudioResource，前端永远只拿 /stream/<sid>。
func TestResolveAudioExpandsURLOption(t *testing.T) {
	f := NewFetcher("test-agent")
	src := &domain.BookSource{
		URL:  "https://src.example",
		Name: "测试音频源",
		Raw: `{"bookSourceName":"测试音频源","bookSourceUrl":"https://src.example",` +
			`"bookSourceType":1,"header":"{\"User-Agent\":\"test-agent\"}",` +
			`"ruleContent":{"content":""}}`,
	}
	b := &domain.Book{
		ID: 1, Name: "测试听书", Origin: "https://src.example",
		BookURL: "https://src.example/book/1",
		Type:    domain.BookTypeAudio, Format: domain.BookFormatAudio,
	}
	ch := &domain.BookChapter{
		BookID: 1, Index: 0, Title: "第一章",
		URL: `https://cdn.example.com/a.mp3,{"headers":{"X-Token":"abc"}}`,
	}

	res, err := f.ResolveAudio(context.Background(), src, b, ch, "")
	if err != nil {
		t.Fatal(err)
	}
	if res.URL != "https://cdn.example.com/a.mp3" {
		t.Fatalf("URL 选项没有被剥离，实际 %q", res.URL)
	}
	if res.Headers["X-Token"] != "abc" {
		t.Fatalf("URL 选项里的请求头丢失: %+v", res.Headers)
	}
	if res.Headers["Referer"] != "https://cdn.example.com/" {
		t.Fatalf("应补默认 Referer（音频站防盗链）: %+v", res.Headers)
	}
	if got := res.Headers["User-Agent"]; got != "test-agent" {
		t.Fatalf("书源 UA 未透传: %q", got)
	}
	if strings.Contains(res.URL, "X-Token") {
		t.Fatal("解析结果里不应残留 URL 选项")
	}
}

func TestResolveAudioRejectsNonHTTP(t *testing.T) {
	f := NewFetcher("")
	src := &domain.BookSource{
		URL: "https://src.example",
		Raw: `{"bookSourceName":"x","bookSourceUrl":"https://src.example",` +
			`"bookSourceType":1,"ruleContent":{"content":""}}`,
	}
	b := &domain.Book{BookURL: "https://src.example/book/1", Type: domain.BookTypeAudio}
	ch := &domain.BookChapter{Index: 0, Title: "第一章", URL: "file:///etc/passwd"}
	if _, err := f.ResolveAudio(context.Background(), src, b, ch, ""); err == nil {
		t.Fatal("非 http(s) 音频地址必须被拒绝")
	}
}
