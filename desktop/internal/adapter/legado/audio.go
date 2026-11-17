package legado

import (
	"context"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
	legadomodel "github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/urlx"
)

// 编译期断言：抓取器同时是音频地址解析器。
var _ port.AudioResolver = (*Fetcher)(nil)

// isAudioSource 判断书源是否为音频类（bookSourceType = 1）。
func isAudioSource(src *legadomodel.BookSource) bool {
	return src != nil && src.BookSourceType == sourceTypeAudio
}

// 少数音频源把 <audio src="..."> 整段当正文返回，抽出第一个 src 即可。
var audioSrcPattern = regexp.MustCompile(`(?is)<(?:audio|source)\b[^>]*\bsrc\s*=\s*["']([^"']+)["']`)

// normalizeAudioRule 把「正文」收敛成一条 URL 规则串。
//
// 对齐原版：AudioPlay.kt 把 WebBook.getContent 的结果原样赋给 durPlayUrl，
// 不做任何文本清洗。这里只多兜一层 HTML 标签，其余一律保持原样——
// 规则串里可能有 ,{...} 选项、{{js}} 和逗号，擅自截断会把真实书源写坏。
func normalizeAudioRule(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	if strings.Contains(s, "<audio") || strings.Contains(s, "<source") {
		if m := audioSrcPattern.FindStringSubmatch(s); len(m) > 1 {
			return strings.TrimSpace(m[1])
		}
	}
	return s
}

// ResolveAudio 把章节「正文」展开成可直接请求的音频资源。
//
// 对齐 Kotlin 的 `AnalyzeUrl(durPlayUrl).getMediaItem()`：URL 选项（method、
// headers、body、js）、书源 header、登录头与 Cookie 都在这里解析完，
// 前端只拿到一个同域代理地址，永远看不到真实 URL 与凭据。
func (f *Fetcher) ResolveAudio(ctx context.Context, src *domain.BookSource, b *domain.Book, ch *domain.BookChapter, nextChapterURL string) (*port.AudioResource, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if src == nil || b == nil || ch == nil {
		return nil, fmt.Errorf("%w: 缺少书源/书籍/章节", domain.ErrInvalidArgument)
	}

	// 先走标准正文流水线：音频源的 content 规则为空时会直接回退 chapter.url，
	// 非空时则可能发起一次请求再解析出播放地址。两条路都要覆盖。
	content, err := f.GetContent(ctx, src, b, ch, nextChapterURL)
	if err != nil {
		return nil, fmt.Errorf("解析音频地址失败: %w", err)
	}
	rule := content.Audio
	if rule == "" {
		rule = content.HTML
	}
	rule = normalizeAudioRule(rule)
	if rule == "" {
		return nil, fmt.Errorf("%w: 该章节没有解析出音频地址，请检查目录与正文规则", domain.ErrNotFound)
	}

	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}
	au := urlx.New(urlx.Options{
		Url:     rule,
		BaseUrl: b.BookURL,
		Source:  engineSrc,
		Book:    toEngineBook(b),
		Chapter: toEngineChapter(ch, b),
	})

	target := strings.TrimSpace(au.Url)
	parsed, err := url.Parse(target)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, fmt.Errorf("%w: 音频地址不是有效的 http(s) 链接", domain.ErrInvalidArgument)
	}

	headers := make(map[string]string, len(au.HeaderMap)+4)
	for k, v := range au.HeaderMap {
		headers[k] = v
	}
	// 登录脚本 putLoginHeader 存下的头不一定进了 GetHeaderMap 的默认分支，补一次。
	for k, v := range engineSrc.GetLoginHeaderMap() {
		if _, ok := headers[k]; !ok {
			headers[k] = v
		}
	}
	if !hasHeader(headers, "Referer") {
		headers["Referer"] = parsed.Scheme + "://" + parsed.Host + "/"
	}
	if c := store.Default().GetCookie(target); c != "" && !hasHeader(headers, "Cookie") {
		headers["Cookie"] = c
	}
	if !hasHeader(headers, "User-Agent") && f.UserAgent != "" {
		headers["User-Agent"] = f.UserAgent
	}

	return &port.AudioResource{URL: target, Headers: headers, Method: au.Method}, nil
}

// hasHeader 忽略大小写判断请求头是否已存在：书源里 `referer` / `Referer`
// 混写很常见，只用 map 下标判断会补出一个重复头。
func hasHeader(headers map[string]string, key string) bool {
	for k := range headers {
		if strings.EqualFold(k, key) {
			return true
		}
	}
	return false
}
