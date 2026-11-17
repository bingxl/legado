package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// AudioResource 是解析完成的真实音频资源。
//
// 书源给的是「URL 规则串」（可能带 ,{...} 选项、{{js}}、相对地址、登录头），
// 必须经引擎的 AnalyzeUrl 展开后才是可请求的 URL。Headers 里含书源 header、
// 登录头与 Cookie，代理发请求时要原样带上，否则防盗链站点直接 403。
type AudioResource struct {
	URL     string
	Headers map[string]string
	Method  string
}

// AudioResolver 把章节「正文」解析成音频资源。
//
// 单独成接口而不是塞进 SourceFetcher：app 层只依赖端口，书源引擎的类型
// 不该渗进用例层；同时不影响既有 SourceFetcher 的测试替身。
type AudioResolver interface {
	ResolveAudio(ctx context.Context, src *domain.BookSource, b *domain.Book, ch *domain.BookChapter, nextChapterURL string) (*AudioResource, error)
}
