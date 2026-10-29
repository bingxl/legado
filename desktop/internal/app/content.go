package app

import (
	"context"
	"fmt"
	"strings"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ContentProvider 屏蔽「本地文件」与「网络书源」两种内容来源的差异，
// 对外统一提供按书 + 章节序号取正文的能力。
//
// 阅读器与导出功能都依赖它，从而避免在两处重复编写分派逻辑。
type ContentProvider struct {
	books    port.BookRepository
	chapters port.ChapterRepository
	sources  port.BookSourceRepository
	parsers  port.LocalBookParserRegistry
	fetcher  port.SourceFetcher
}

// NewContentProvider 构造内容供给器。
func NewContentProvider(
	books port.BookRepository,
	chapters port.ChapterRepository,
	sources port.BookSourceRepository,
	parsers port.LocalBookParserRegistry,
	fetcher port.SourceFetcher,
) *ContentProvider {
	return &ContentProvider{
		books:    books,
		chapters: chapters,
		sources:  sources,
		parsers:  parsers,
		fetcher:  fetcher,
	}
}

// Chapter 取指定书籍某一章的正文。
func (p *ContentProvider) Chapter(ctx context.Context, bookID int64, index int) (*port.ChapterContent, error) {
	book, err := p.books.Get(ctx, bookID)
	if err != nil {
		return nil, err
	}
	chapter, err := p.chapters.Get(ctx, bookID, index)
	if err != nil {
		return nil, err
	}
	return p.content(ctx, book, chapter, p.nextChapterURL(ctx, bookID, index))
}

// nextChapterURL 取下一章的地址，供抓取器给书源的「正文下一页」规则踩刹车。
//
// 部分书源的 ruleContent.nextContentUrl 选择器会同时命中「下一页」和「下一章」，
// 或者干脆只命中「下一章」，此时若继续顺着抓，下一章正文会被拼进本章结尾。
// 取不到（最后一章、目录缺失）时返回空串，抓取器会跳过这项校验。
func (p *ContentProvider) nextChapterURL(ctx context.Context, bookID int64, index int) string {
	next, err := p.chapters.Get(ctx, bookID, index+1)
	if err != nil || next == nil {
		return ""
	}
	return next.URL
}

// content 按来源类型分派到解析器或抓取器。
func (p *ContentProvider) content(ctx context.Context, book *domain.Book, chapter *domain.BookChapter, nextChapterURL string) (*port.ChapterContent, error) {
	if book.IsLocal() {
		if p.parsers == nil {
			return nil, fmt.Errorf("%w: 未配置本地书解析器", domain.ErrNotConfigured)
		}
		parser, err := p.parsers.Resolve(book.Format)
		if err != nil {
			return nil, err
		}
		return parser.Content(ctx, book.BookURL, chapter)
	}

	// 网络书：按其 origin 定位书源后抓取。
	if p.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	src, err := p.sources.FindByURL(ctx, book.Origin)
	if err != nil {
		return nil, fmt.Errorf("定位书源失败: %w", err)
	}
	return p.fetcher.GetContent(ctx, src, book, chapter, nextChapterURL)
}

// BookAndChapters 返回书籍与其全部章节，供导出使用。
func (p *ContentProvider) BookAndChapters(ctx context.Context, bookID int64) (*domain.Book, []*domain.BookChapter, error) {
	book, err := p.books.Get(ctx, bookID)
	if err != nil {
		return nil, nil, err
	}
	chapters, err := p.chapters.List(ctx, bookID)
	if err != nil {
		return nil, nil, err
	}
	return book, chapters, nil
}

// FetchContent 供导出回调使用：按章节取正文。
func (p *ContentProvider) FetchContent(ctx context.Context, book *domain.Book) func(*domain.BookChapter) (*port.ChapterContent, error) {
	return func(ch *domain.BookChapter) (*port.ChapterContent, error) {
		return p.content(ctx, book, ch, p.nextChapterURL(ctx, book.ID, ch.Index))
	}
}

// NormalizeTitle 清理章节标题中的空白，用于目录展示与导出。
func NormalizeTitle(title string) string {
	return strings.TrimSpace(strings.ReplaceAll(title, "\u00a0", " "))
}
