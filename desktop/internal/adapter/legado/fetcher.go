// Package legado 把 desktop 的领域模型与 legado-go 书源引擎对接起来。
//
// 之所以需要这一层：legado-go 是独立的规则引擎模块，有自己的模型定义
// （model.Book / model.BookSource / model.BookChapter）。让 app 层直接使用
// 这些第三方类型会破坏架构分层，因此在这里完成模型转换。
package legado

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	legadomodel "github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/source"
	"github.com/legado/legado-go/pkg/webbook"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// Fetcher 实现 port.SourceFetcher，内部委托 legado-go 的 webbook 包。
type Fetcher struct {
	// UserAgent 是发起请求时使用的 UA，为空时使用引擎默认值。
	UserAgent string
}

// NewFetcher 创建书源抓取器。
func NewFetcher(userAgent string) *Fetcher { return &Fetcher{UserAgent: userAgent} }

var _ port.SourceFetcher = (*Fetcher)(nil)

// Search 在单个书源内搜索。
func (f *Fetcher) Search(ctx context.Context, src *domain.BookSource, keyword string, page int) ([]*domain.SearchResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}
	list, err := webbook.SearchBook(engineSrc, keyword, page)
	if err != nil {
		return nil, fmt.Errorf("搜索失败: %w", err)
	}
	return fromEngineSearchList(list, src), nil
}

// Explore 拉取发现页。
func (f *Fetcher) Explore(ctx context.Context, src *domain.BookSource, url string, page int) ([]*domain.SearchResult, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}
	list, err := webbook.ExploreBook(engineSrc, url, page)
	if err != nil {
		return nil, fmt.Errorf("拉取发现页失败: %w", err)
	}
	return fromEngineSearchList(list, src), nil
}

// HasExplore 报告书源是否声明了发现地址。
func (f *Fetcher) HasExplore(src *domain.BookSource) bool {
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return false
	}
	return engineSrc.IsEnabledExplore() && strings.TrimSpace(engineSrc.ExploreUrl) != ""
}

// ExploreKinds 解析书源声明的发现分类。
//
// 这是纯本地解析（exploreUrl 是书源 JSON 里的一个字段），不发网络请求，
// 因此可以被「列出所有可发现书源」这种批量场景直接调用。
func (f *Fetcher) ExploreKinds(ctx context.Context, src *domain.BookSource) ([]domain.ExploreKind, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}
	// 书源可以显式关闭发现（enabledExplore=false），此时即使配了 exploreUrl 也不该出现。
	if !engineSrc.IsEnabledExplore() {
		return nil, nil
	}
	kinds := webbook.GetExploreKinds(engineSrc)
	out := make([]domain.ExploreKind, 0, len(kinds))
	for _, k := range kinds {
		title := strings.TrimSpace(k.Title)
		if title == "" {
			// 分类名缺失时退化成「全部」，比显示一长串 URL 更可读。
			title = "全部"
		}
		out = append(out, domain.ExploreKind{Title: title, URL: strings.TrimSpace(k.Url)})
	}
	return out, nil
}

// GetBookInfo 拉取书籍详情与目录。
func (f *Fetcher) GetBookInfo(ctx context.Context, src *domain.BookSource, b *domain.Book) (*domain.Book, []*domain.BookChapter, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, nil, err
	}
	engineBook := toEngineBook(b)

	if err := webbook.GetBookInfo(engineSrc, engineBook); err != nil {
		return nil, nil, fmt.Errorf("获取书籍详情失败: %w", err)
	}
	engineChapters, err := webbook.GetChapterList(engineSrc, engineBook, true)
	if err != nil {
		return nil, nil, fmt.Errorf("获取目录失败: %w", err)
	}

	book := fromEngineBook(engineBook)
	book.ID = b.ID
	book.GroupID = b.GroupID
	book.Origin = src.URL
	book.Kind = domain.BookKindWeb
	return book, fromEngineChapters(engineChapters, b.ID), nil
}

// GetContent 抓取章节正文。
func (f *Fetcher) GetContent(ctx context.Context, src *domain.BookSource, b *domain.Book, ch *domain.BookChapter, nextChapterURL string) (*port.ChapterContent, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}
	engineBook := toEngineBook(b)
	engineChapter := toEngineChapter(ch, b)

	html, err := webbook.GetContent(engineSrc, engineBook, engineChapter, nextChapterURL)
	if err != nil {
		return nil, fmt.Errorf("获取正文失败: %w", err)
	}

	content := &port.ChapterContent{Title: ch.Title, HTML: html}
	// 漫画源：正文是一串 <img>，额外抽出图片列表交给阅读器走图片流渲染。
	// 保留 HTML 原样，导出（EPUB）还需要它来内嵌图片。
	if isComicSource(engineSrc) {
		content.Images = extractImages(html, ch.URL)
	}
	return content, nil
}

// Validate 校验书源规则。
func (f *Fetcher) Validate(ctx context.Context, src *domain.BookSource, items port.CheckItems) ([]port.ValidationIssue, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	engineSrc, err := toEngineSource(src)
	if err != nil {
		return nil, err
	}

	// 先做本地静态校验：不联网也能发现必填字段缺失等问题。
	result := source.Validate(engineSrc)
	issues := fromEngineIssues(result.Issues)

	// 静态校验不通过时无需再联网，直接返回。
	if items.NeedNetwork() && !hasBlockingIssue(issues) {
		online := source.ValidateOnline(engineSrc, "", source.CheckItems{
			Search:  items.Search,
			Info:    items.Info,
			Toc:     items.TOC,
			Content: items.Content,
		})
		issues = append(issues, fromEngineIssues(online.Issues)...)
	}
	return issues, nil
}

// toEngineSource 把领域书源还原为引擎模型。
//
// 书源以原始 JSON 持久化，因此这里直接反序列化即可，无需逐字段映射。
func toEngineSource(src *domain.BookSource) (*legadomodel.BookSource, error) {
	if src == nil {
		return nil, fmt.Errorf("%w: 书源为空", domain.ErrInvalidArgument)
	}
	if strings.TrimSpace(src.Raw) == "" {
		return nil, fmt.Errorf("%w: 书源缺少原始规则数据", domain.ErrInvalidArgument)
	}
	out := &legadomodel.BookSource{}
	if err := json.Unmarshal([]byte(src.Raw), out); err != nil {
		return nil, fmt.Errorf("%w: 书源规则解析失败: %s", domain.ErrParseFailed, err.Error())
	}
	// 以管理字段为准，覆盖 raw 中可能缺失或不一致的关键信息。
	if out.BookSourceUrl == "" {
		out.BookSourceUrl = src.URL
	}
	if out.BookSourceName == "" {
		out.BookSourceName = src.Name
	}
	return out, nil
}

// toEngineBook 领域书籍 → 引擎书籍。
func toEngineBook(b *domain.Book) *legadomodel.Book {
	out := legadomodel.NewBook()
	if b == nil {
		return out
	}
	out.Name = b.Name
	out.Author = b.Author
	out.BookUrl = b.BookURL
	out.Origin = b.Origin
	out.Intro = b.Intro
	out.CoverUrl = b.CoverURL
	out.TotalChapterNum = b.TotalChapters
	out.DurChapterIndex = b.DurChapterIndex
	out.DurChapterTitle = b.DurChapterTitle
	// 书源在列表页 @put 的变量要靠它恢复：目录/正文规则里的 @get 从这里取值。
	out.Variable = b.Variable
	if b.Variable != "" {
		out.LoadJSON(b.Variable)
	}
	return out
}

// fromEngineBook 引擎书籍 → 领域书籍。
func fromEngineBook(b *legadomodel.Book) *domain.Book {
	out := &domain.Book{
		Name:            b.Name,
		Author:          b.Author,
		Intro:           b.Intro,
		CoverURL:        b.CoverUrl,
		Kind:            domain.BookKindWeb,
		Origin:          b.Origin,
		OriginName:      b.OriginName,
		BookURL:         b.BookUrl,
		TotalChapters:   b.TotalChapterNum,
		LastChapter:     b.LatestChapterTitle,
		DurChapterIndex: b.DurChapterIndex,
		DurChapterTitle: b.DurChapterTitle,
	}
	// 详情页规则也可能 @put 变量，回写一次，别把列表页带来的那份覆盖成空。
	if s := b.ToJSON(); s != "" {
		out.Variable = s
	}
	return out
}

// fromEngineSearchList 引擎搜索结果 → 领域搜索结果。
func fromEngineSearchList(in []*legadomodel.SearchBook, src *domain.BookSource) []*domain.SearchResult {
	out := make([]*domain.SearchResult, 0, len(in))
	for _, s := range in {
		origin := s.Origin
		if origin == "" && src != nil {
			origin = src.URL
		}
		out = append(out, &domain.SearchResult{
			Name:        s.Name,
			Author:      s.Author,
			Cover:       s.CoverUrl,
			Intro:       s.Intro,
			BookURL:     s.BookUrl,
			Origin:      origin,
			OriginName:  s.OriginName,
			LastChapter: s.LatestChapterTitle,
			Kind:        s.Kind,
			Variable:    s.Variable,
		})
	}
	return out
}

// toEngineChapter 领域章节 → 引擎章节。
func toEngineChapter(ch *domain.BookChapter, b *domain.Book) *legadomodel.BookChapter {
	out := legadomodel.NewBookChapter(b.BookURL)
	out.Index = ch.Index
	out.Title = ch.Title
	out.Url = ch.URL
	out.IsVolume = ch.IsVolume
	return out
}

// fromEngineChapters 引擎章节 → 领域章节。
func fromEngineChapters(in []*legadomodel.BookChapter, bookID int64) []*domain.BookChapter {
	out := make([]*domain.BookChapter, 0, len(in))
	for i, c := range in {
		url := c.Url
		if url == "" {
			// 部分书源只给相对地址，退而使用绝对地址计算结果。
			url = c.GetAbsoluteURL()
		}
		out = append(out, &domain.BookChapter{
			BookID:   bookID,
			Index:    indexOr(c.Index, i),
			Title:    c.Title,
			URL:      url,
			IsVolume: c.IsVolume,
		})
	}
	return out
}

// fromEngineIssues 引擎校验问题 → 端口校验问题。
func fromEngineIssues(in []source.Issue) []port.ValidationIssue {
	out := make([]port.ValidationIssue, 0, len(in))
	for _, i := range in {
		out = append(out, port.ValidationIssue{
			Level:   mapLevel(string(i.Level)),
			Field:   i.Field,
			Message: i.Message,
		})
	}
	return out
}

// mapLevel 把引擎的问题级别映射为端口级别。
func mapLevel(level string) port.IssueLevel {
	switch strings.ToUpper(level) {
	case "ERROR", "FATAL":
		return port.IssueLevelError
	case "WARN", "WARNING":
		return port.IssueLevelWarning
	default:
		return port.IssueLevelInfo
	}
}

// hasBlockingIssue 判断是否存在 error 级问题。
func hasBlockingIssue(issues []port.ValidationIssue) bool {
	for _, i := range issues {
		if i.Level == port.IssueLevelError {
			return true
		}
	}
	return false
}

// indexOr 在引擎未设置序号时以遍历下标兜底。
func indexOr(index, fallback int) int {
	if index > 0 {
		return index
	}
	return fallback
}
