package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceService 负责书源的增删改查、导入导出、校验，以及基于书源的搜索与发现。
type SourceService struct {
	sources  port.BookSourceRepository
	subs     port.SubscriptionRepository
	books    port.BookRepository
	chapters port.ChapterRepository
	fetcher  port.SourceFetcher
	events   port.EventBus

	kindsMu    sync.Mutex
	kindsCache map[int64]exploreKindsEntry
}

// exploreKindsEntry 缓存某个书源解析出的发现分类。
//
// 缓存的意义不只是省 CPU：exploreUrl 若是 JS 形式，求值时常要 java.ajax
// 抓一次页面，一次全量解析就是十几个网络往返。没有缓存的话每次进「发现」
// 页都要重来一遍。
type exploreKindsEntry struct {
	raw   string // 解析时的书源原文，用于判断书源是否被改过
	kinds []domain.ExploreKind
	at    time.Time
}

const (
	// exploreKindsTTL 是分类缓存的有效期。
	exploreKindsTTL = 10 * time.Minute
)

// SourceDeps 聚合 SourceService 的依赖。
type SourceDeps struct {
	Sources  port.BookSourceRepository
	Subs     port.SubscriptionRepository
	Books    port.BookRepository
	Chapters port.ChapterRepository
	Fetcher  port.SourceFetcher
	Events   port.EventBus
}

// NewSourceService 构造书源服务。
func NewSourceService(d SourceDeps) *SourceService {
	return &SourceService{
		sources:  d.Sources,
		subs:     d.Subs,
		books:    d.Books,
		chapters: d.Chapters,
		fetcher:  d.Fetcher,
		events:   d.Events,
	}
}

// List 列出书源；group 为空表示全部。
func (s *SourceService) List(ctx context.Context, group string) ([]dto.SourceView, error) {
	list, err := s.sources.List(ctx, group)
	if err != nil {
		return nil, err
	}
	return dto.NewSourceViews(list), nil
}

// Get 获取单个书源。
func (s *SourceService) Get(ctx context.Context, id int64) (dto.SourceView, error) {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return dto.SourceView{}, err
	}
	return dto.NewSourceView(src), nil
}

// Save 新增或更新书源。id 为 0 时新增，否则更新。
//
// 传入的 Raw 若缺少 bookSourceUrl，会尝试从 URL 字段补全，
// 保证管理字段与原始 JSON 不脱节。
func (s *SourceService) Save(ctx context.Context, id int64, name, group, url, comment, raw string, enabled bool, order int) (dto.SourceView, error) {
	if url == "" {
		return dto.SourceView{}, fmt.Errorf("%w: 书源 URL 不能为空", domain.ErrInvalidArgument)
	}
	src := &domain.BookSource{
		ID:      id,
		Name:    name,
		Group:   group,
		URL:     url,
		Comment: comment,
		Raw:     raw,
		Enabled: enabled,
		Order:   order,
	}
	if src.Name == "" {
		src.Name = url
	}
	src.Raw = ensureSourceURL(src.Raw, url)

	var err error
	if id == 0 {
		err = s.sources.Create(ctx, src)
	} else {
		err = s.sources.Update(ctx, src)
	}
	if err != nil {
		return dto.SourceView{}, err
	}
	return dto.NewSourceView(src), nil
}

// Delete 删除书源。
func (s *SourceService) Delete(ctx context.Context, id int64) error {
	return s.sources.Delete(ctx, id)
}

// SetEnabled 启停书源。
func (s *SourceService) SetEnabled(ctx context.Context, id int64, enabled bool) error {
	src, err := s.sources.Get(ctx, id)
	if err != nil {
		return err
	}
	src.Enabled = enabled
	return s.sources.Update(ctx, src)
}

// Import 从 Legado 书源 JSON 批量导入。
//
// 输入支持三种形态：单个书源对象、书源数组、以及 Legado 导出的备份文件（含 data 字段）。
// 已存在相同 URL 的书源默认覆盖更新，并返回最终状态，便于前端刷新列表。
func (s *SourceService) Import(ctx context.Context, data []byte, overwrite bool) (*dto.SourceImportResult, error) {
	items, err := decodeSourcePayload(data)
	if err != nil {
		return nil, err
	}
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: 未解析到任何书源", domain.ErrParseFailed)
	}

	result := &dto.SourceImportResult{
		Sources:  make([]dto.SourceView, 0, len(items)),
		Failures: make([]dto.SourceFailure, 0),
	}

	// 注意：导入是本地写库，不发「书源校验进度」事件——
	// 该事件由前端当作「校验中」渲染，误用会让导入时的进度条显示成校验态。
	for _, raw := range items {
		var probe map[string]any
		if err := json.Unmarshal(raw, &probe); err != nil {
			result.Failures = append(result.Failures, dto.SourceFailure{Reason: "JSON 解析失败: " + err.Error()})
			continue
		}
		url := stringField(probe, "bookSourceUrl")
		name := stringField(probe, "bookSourceName")
		group := stringField(probe, "bookSourceGroup")
		if url == "" {
			result.Failures = append(result.Failures, dto.SourceFailure{
				Name: name, Reason: "缺少 bookSourceUrl 字段",
			})
			continue
		}

		existing, err := s.sources.FindByURL(ctx, url)
		switch {
		case err == nil && !overwrite:
			result.Skipped++
			result.Sources = append(result.Sources, dto.NewSourceView(existing))
			continue
		case err == nil:
			existing.Name = firstNonEmpty(name, existing.Name)
			existing.Group = firstNonEmpty(group, existing.Group)
			existing.Raw = string(raw)
			existing.LastUpdateAt = time.Now()
			if err := s.sources.Update(ctx, existing); err != nil {
				result.Failures = append(result.Failures, dto.SourceFailure{Name: name, URL: url, Reason: err.Error()})
				continue
			}
			result.Updated++
			result.Sources = append(result.Sources, dto.NewSourceView(existing))
		default:
			src := &domain.BookSource{
				Name:  firstNonEmpty(name, url),
				Group: group,
				URL:   url,
				Raw:   string(raw),
				// 导入的书源默认启用，避免用户导入后还要逐个开启。
				Enabled:      true,
				Order:        0,
				LastUpdateAt: time.Now(),
			}
			if err := s.sources.Create(ctx, src); err != nil {
				result.Failures = append(result.Failures, dto.SourceFailure{Name: name, URL: url, Reason: err.Error()})
				continue
			}
			result.Imported++
			result.Sources = append(result.Sources, dto.NewSourceView(src))
		}
	}
	return result, nil
}

// Export 导出书源为 Legado 兼容的 JSON 数组；ids 为空时导出全部。
func (s *SourceService) Export(ctx context.Context, ids []int64) ([]byte, error) {
	var list []*domain.BookSource
	var err error

	if len(ids) == 0 {
		list, err = s.sources.List(ctx, "")
	} else {
		list = make([]*domain.BookSource, 0, len(ids))
		for _, id := range ids {
			src, e := s.sources.Get(ctx, id)
			if e != nil {
				continue // 跳过已删除的书源
			}
			list = append(list, src)
		}
	}
	if err != nil {
		return nil, err
	}

	out := make([]json.RawMessage, 0, len(list))
	for _, src := range list {
		raw := src.Raw
		if strings.TrimSpace(raw) == "" {
			// 无原始 JSON 时，用管理字段拼一个最小可用书源。
			minimal, _ := json.Marshal(map[string]any{
				"bookSourceUrl":   src.URL,
				"bookSourceName":  src.Name,
				"bookSourceGroup": src.Group,
			})
			raw = string(minimal)
		}
		out = append(out, json.RawMessage(raw))
	}
	return json.MarshalIndent(out, "", "  ")
}

// Validate 校验一个或多个书源；ids 为空时校验全部启用书源。
func (s *SourceService) Validate(ctx context.Context, ids []int64, items port.CheckItems) ([]dto.SourceCheckResult, error) {
	targets, err := s.pickSources(ctx, ids)
	if err != nil {
		return nil, err
	}
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}

	results := make([]dto.SourceCheckResult, 0, len(targets))
	for i, src := range targets {
		s.emitCheckProgress(ctx, len(targets), i+1, src.Name)

		issues, err := s.fetcher.Validate(ctx, src, items)
		if err != nil {
			// 单个书源校验失败不中断整体，记为一条 error 级问题。
			issues = []port.ValidationIssue{{Level: port.IssueLevelError, Message: err.Error()}}
		}
		results = append(results, dto.SourceCheckResult{
			SourceID:   src.ID,
			SourceName: src.Name,
			OK:         !hasErrorIssue(issues),
			Issues:     dto.NewValidationIssues(issues),
		})

		src.LastUpdateAt = time.Now()
		_ = s.sources.Update(ctx, src)
	}
	return results, nil
}

// ListExploreSources 列出开启「发现」的书源，只带名字与分组。
//
// 与 Legado 原版一致，条件是「启用 + 开启发现 + 配了 exploreUrl」。
// 分类不在这里解析：展开某个源时再按需取（见 ExploreKinds），
// 否则首屏要为所有源各跑一遍可能联网的规则。
func (s *SourceService) ListExploreSources(ctx context.Context) ([]dto.ExploreSourceBrief, error) {
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	list, err := s.sources.ListEnabled(ctx)
	if err != nil {
		return nil, err
	}
	out := make([]dto.ExploreSourceBrief, 0, len(list))
	for _, src := range list {
		if !s.fetcher.HasExplore(src) {
			continue
		}
		out = append(out, dto.ExploreSourceBrief{ID: src.ID, Name: src.Name, Group: src.Group})
	}
	return out, nil
}

// ExploreKinds 解析指定书源的发现分类。
//
// 只在用户展开某个源时调用。分类解析可能要执行书源 JS（其中常含网络请求），
// 因此结果按书源内容做进程内缓存：规则没变就不重复解析。
func (s *SourceService) ExploreKinds(ctx context.Context, sourceID int64) ([]dto.ExploreKindView, error) {
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	src, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	kinds, err := s.exploreKinds(ctx, src)
	if err != nil {
		return nil, fmt.Errorf("解析发现分类失败: %w", err)
	}
	views := make([]dto.ExploreKindView, 0, len(kinds))
	for _, k := range kinds {
		views = append(views, dto.NewExploreKindView(k))
	}
	return views, nil
}

// exploreKinds 取书源的发现分类，带进程内缓存。
//
// 解析失败不写缓存——否则用户改好书源后，10 分钟内都还在看旧错误。
func (s *SourceService) exploreKinds(ctx context.Context, src *domain.BookSource) ([]domain.ExploreKind, error) {
	s.kindsMu.Lock()
	if e, ok := s.kindsCache[src.ID]; ok && e.raw == src.Raw && time.Since(e.at) < exploreKindsTTL {
		kinds := e.kinds
		s.kindsMu.Unlock()
		return kinds, nil
	}
	s.kindsMu.Unlock()

	kinds, err := s.fetcher.ExploreKinds(ctx, src)
	if err != nil {
		return nil, err
	}

	s.kindsMu.Lock()
	if s.kindsCache == nil {
		s.kindsCache = make(map[int64]exploreKindsEntry)
	}
	s.kindsCache[src.ID] = exploreKindsEntry{raw: src.Raw, kinds: kinds, at: time.Now()}
	s.kindsMu.Unlock()
	return kinds, nil
}

// Explore 拉取指定书源某个分类下的书单。
//
// url 为空时由引擎退回书源的首个分类，方便前端「点源就出内容」。
func (s *SourceService) Explore(ctx context.Context, sourceID int64, url string, page int) ([]dto.SearchResultView, error) {
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	src, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	if page < 1 {
		page = 1
	}
	res, err := s.fetcher.Explore(ctx, src, url, page)
	if err != nil {
		return nil, err
	}
	return dto.NewSearchResultViews(res), nil
}

// Search 在指定书源内搜索。
func (s *SourceService) Search(ctx context.Context, sourceID int64, keyword string, page int) ([]dto.SearchResultView, error) {
	if strings.TrimSpace(keyword) == "" {
		return nil, fmt.Errorf("%w: 搜索关键词不能为空", domain.ErrInvalidArgument)
	}
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	src, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	if page < 1 {
		page = 1
	}
	res, err := s.fetcher.Search(ctx, src, keyword, page)
	if err != nil {
		return nil, err
	}
	return dto.NewSearchResultViews(res), nil
}

// SearchAll 在全部启用书源中并发搜索。
func (s *SourceService) SearchAll(ctx context.Context, keyword string, page int) ([]dto.SearchResultView, error) {
	if s.fetcher == nil {
		return nil, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	list, err := s.sources.ListEnabled(ctx)
	if err != nil {
		return nil, err
	}
	if page < 1 {
		page = 1
	}

	out := make([]dto.SearchResultView, 0)
	// 串行执行以控制对源站的请求压力；书源数量通常有限，串行已足够。
	for _, src := range list {
		res, err := s.fetcher.Search(ctx, src, keyword, page)
		if err != nil {
			continue // 单个书源失败不影响其余书源的结果
		}
		out = append(out, dto.NewSearchResultViews(res)...)
	}
	return out, nil
}

// AddToShelf 把搜索结果加入书架：拉取详情与目录后一次性落库。
//
// name/author 是列表页（搜索/发现）已经解析出来的信息，先填进 book 再抓详情：
// 详情规则取到值会覆盖它（见 webbook.analyzeBookInfo：规则为空时保留旧值），
// 取不到时也不至于因为书名为空而落库失败。
//
// variable 同样是列表页的产物：书源用 @put 存下的变量（JSON 对象串），
// 目录/正文地址里的 @get 依赖它，丢了就会请求到参数为空的地址。
func (s *SourceService) AddToShelf(ctx context.Context, sourceID int64, bookURL, name, author, variable string, groupID int64) (dto.BookBrief, error) {
	if s.fetcher == nil {
		return dto.BookBrief{}, fmt.Errorf("%w: 未配置书源抓取器", domain.ErrNotConfigured)
	}
	src, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return dto.BookBrief{}, err
	}

	// 已存在则直接返回，避免重复抓取。
	if existing, err := s.books.FindByURL(ctx, src.URL, bookURL); err == nil {
		return dto.NewBookBrief(existing), nil
	}

	book := &domain.Book{
		Name:     strings.TrimSpace(name),
		Author:   strings.TrimSpace(author),
		Origin:   src.URL,
		BookURL:  bookURL,
		Kind:     domain.BookKindWeb,
		Variable: variable,
		GroupID:  groupID,
	}
	book, chapters, err := s.fetcher.GetBookInfo(ctx, src, book)
	if err != nil {
		return dto.BookBrief{}, err
	}
	if strings.TrimSpace(book.Name) == "" {
		return dto.BookBrief{}, fmt.Errorf("%w: 该书源详情页没有解析出书名，请在书源规则里检查「书名」", domain.ErrInvalidArgument)
	}

	if err := s.books.Create(ctx, book); err != nil {
		return dto.BookBrief{}, err
	}
	if err := s.chapters.ReplaceAll(ctx, book.ID, chapters); err != nil {
		return dto.BookBrief{}, err
	}
	return dto.NewBookBrief(book), nil
}

// pickSources 选出待校验的书源；ids 为空则取全部启用书源。
func (s *SourceService) pickSources(ctx context.Context, ids []int64) ([]*domain.BookSource, error) {
	if len(ids) == 0 {
		return s.sources.ListEnabled(ctx)
	}
	out := make([]*domain.BookSource, 0, len(ids))
	for _, id := range ids {
		src, err := s.sources.Get(ctx, id)
		if err != nil {
			continue
		}
		out = append(out, src)
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%w: 未找到可校验的书源", domain.ErrNotFound)
	}
	return out, nil
}

// emitCheckProgress 推送书源校验进度。
func (s *SourceService) emitCheckProgress(ctx context.Context, total, done int, current string) {
	if s.events == nil {
		return
	}
	_ = s.events.Emit(ctx, port.EventSourceCheckProgress, dto.SourceCheckProgress{
		Total:   total,
		Done:    done,
		Current: current,
	})
}

// hasErrorIssue 判断是否存在 error 级问题。
func hasErrorIssue(issues []port.ValidationIssue) bool {
	for _, i := range issues {
		if i.Level == port.IssueLevelError {
			return true
		}
	}
	return false
}

// decodeSourcePayload 把各类导入载荷规整为书源 JSON 数组。
//
// 兼容三种形态：
//  1. [{...}, {...}]         —— 书源数组
//  2. {...}                  —— 单个书源对象
//  3. {"data": [...]}        —— Legado 备份文件
func decodeSourcePayload(data []byte) ([]json.RawMessage, error) {
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		return nil, fmt.Errorf("%w: 内容为空", domain.ErrParseFailed)
	}

	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err == nil {
		return arr, nil
	}

	var obj map[string]json.RawMessage
	if err := json.Unmarshal(data, &obj); err == nil {
		if inner, ok := obj["data"]; ok {
			if innerArr, err := decodeSourcePayload(inner); err == nil {
				return innerArr, nil
			}
		}
		// 单个书源对象。
		return []json.RawMessage{json.RawMessage(trimmed)}, nil
	}

	return nil, fmt.Errorf("%w: 不是合法的 JSON", domain.ErrParseFailed)
}

// stringField 从 map 中取字符串字段，缺失或类型不符时返回空串。
func stringField(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok {
		return ""
	}
	s, _ := v.(string)
	return s
}

// ensureSourceURL 保证原始 JSON 中含 bookSourceUrl，缺失时注入。
func ensureSourceURL(raw, url string) string {
	if url == "" || strings.TrimSpace(raw) == "" {
		return raw
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return raw // 非法 JSON 原样保留，由校验环节报错
	}
	if stringField(m, "bookSourceUrl") == "" {
		m["bookSourceUrl"] = url
		if patched, err := json.Marshal(m); err == nil {
			return string(patched)
		}
	}
	return raw
}
