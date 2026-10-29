package dto

import (
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceView 是书源在管理界面上的视图。
//
// Raw 保留原始 JSON，供前端的高级编辑器直接使用；
// 表单编辑器则使用 Name/Group/Enabled 等结构化字段。
type SourceView struct {
	ID           int64      `json:"id"`
	Name         string     `json:"name"`
	Group        string     `json:"group"`
	URL          string     `json:"url"`
	Enabled      bool       `json:"enabled"`
	Order        int        `json:"order"`
	Comment      string     `json:"comment"`
	Raw          string     `json:"raw"`
	LastUpdateAt *time.Time `json:"lastUpdateAt"`
	CreatedAt    time.Time  `json:"createdAt"`
}

// NewSourceView 从领域实体转换书源视图。
func NewSourceView(s *domain.BookSource) SourceView {
	var last *time.Time
	if !s.LastUpdateAt.IsZero() {
		t := s.LastUpdateAt
		last = &t
	}
	return SourceView{
		ID:           s.ID,
		Name:         s.Name,
		Group:        s.Group,
		URL:          s.URL,
		Enabled:      s.Enabled,
		Order:        s.Order,
		Comment:      s.Comment,
		Raw:          s.Raw,
		LastUpdateAt: last,
		CreatedAt:    s.CreatedAt,
	}
}

// NewSourceViews 批量转换书源视图。
func NewSourceViews(sources []*domain.BookSource) []SourceView {
	out := make([]SourceView, 0, len(sources))
	for _, s := range sources {
		out = append(out, NewSourceView(s))
	}
	return out
}

// ValidationIssue 是书源校验发现的问题（镜像 port.ValidationIssue，
// 避免把端口类型泄漏到前端契约中）。
type ValidationIssue struct {
	Level   string `json:"level"` // error | warning | info
	Field   string `json:"field"`
	Message string `json:"message"`
}

// NewValidationIssue 转换校验问题。
func NewValidationIssue(i port.ValidationIssue) ValidationIssue {
	return ValidationIssue{Level: string(i.Level), Field: i.Field, Message: i.Message}
}

// NewValidationIssues 批量转换校验问题。
func NewValidationIssues(in []port.ValidationIssue) []ValidationIssue {
	out := make([]ValidationIssue, 0, len(in))
	for _, i := range in {
		out = append(out, NewValidationIssue(i))
	}
	return out
}

// SourceCheckResult 是单个书源的校验结论。
type SourceCheckResult struct {
	SourceID   int64             `json:"sourceId"`
	SourceName string            `json:"sourceName"`
	OK         bool              `json:"ok"` // 无 error 级问题即为通过
	Issues     []ValidationIssue `json:"issues"`
}

// SourceFailure 描述导入过程中失败的一条书源。
type SourceFailure struct {
	Name   string `json:"name"`
	URL    string `json:"url"`
	Reason string `json:"reason"`
}

// SourceImportResult 是书源导入的汇总结果。
type SourceImportResult struct {
	Imported int             `json:"imported"` // 新增条数
	Updated  int             `json:"updated"`  // 覆盖更新条数
	Skipped  int             `json:"skipped"`  // 重复跳过条数
	Sources  []SourceView    `json:"sources"`  // 受影响书源的最终状态
	Failures []SourceFailure `json:"failures"` // 解析失败的条目
}

// SearchResultView 是搜索/发现结果视图。
type SearchResultView struct {
	Name        string `json:"name"`
	Author      string `json:"author"`
	Cover       string `json:"cover"`
	Intro       string `json:"intro"`
	BookURL     string `json:"bookUrl"`
	Origin      string `json:"origin"`
	OriginName  string `json:"originName"`
	LastChapter string `json:"lastChapter"`
	Kind        string `json:"kind"`
}

// NewSearchResultView 从领域实体转换搜索结果视图。
func NewSearchResultView(r *domain.SearchResult) SearchResultView {
	if r == nil {
		return SearchResultView{}
	}
	return SearchResultView{
		Name:        r.Name,
		Author:      r.Author,
		Cover:       r.Cover,
		Intro:       r.Intro,
		BookURL:     r.BookURL,
		Origin:      r.Origin,
		OriginName:  r.OriginName,
		LastChapter: r.LastChapter,
		Kind:        r.Kind,
	}
}

// NewSearchResultViews 批量转换搜索结果视图。
func NewSearchResultViews(in []*domain.SearchResult) []SearchResultView {
	out := make([]SearchResultView, 0, len(in))
	for _, r := range in {
		out = append(out, NewSearchResultView(r))
	}
	return out
}

// ExploreKindView 是发现页上的一个分类入口。
//
// Paged 表示该分类地址里带 {{page}} 分页变量——只有这时「下一页」才有意义。
// 桌面端据此决定是否显示翻页按钮，避免用户点了没反应。
type ExploreKindView struct {
	Title string `json:"title"`
	URL   string `json:"url"`
	Paged bool   `json:"paged"`
}

// NewExploreKindView 转换单个分类。
// 「是否支持翻页」由地址里有没有分页变量决定，与具体分类无关。
func NewExploreKindView(k domain.ExploreKind) ExploreKindView {
	return ExploreKindView{
		Title: k.Title,
		URL:   k.URL,
		Paged: strings.Contains(k.URL, "{{page}}") || strings.Contains(k.URL, "@page"),
	}
}

// ExploreSourceBrief 是发现页列表里的一个书源条目。
//
// 这里刻意**不带分类**：Legado 原版的发现页是折叠列表，展开某个源时才去
// 解析它的分类（部分源的 exploreUrl 是一段要联网的 JS，全部预解析会让
// 首屏等十几秒）。因此列表只传名字与分组，分类由 ExploreKinds 单独按需取。
type ExploreSourceBrief struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	Group string `json:"group"`
}
