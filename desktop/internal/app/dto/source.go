package dto

import (
	"regexp"
	"time"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceView 是书源在管理界面上的视图。
//
// Raw 保留原始 JSON，供前端的高级编辑器直接使用；
// 表单编辑器则使用 Name/Group/Enabled 等结构化字段。
// 注意：Raw 单条可达几十 KB，只允许在单条接口（Get/Save/订阅同步）里填充；
// 列表接口必须走 NewSourceBriefViews——上千书源时多传的 Raw 会把列表
// 响应撑到几十 MB，是书源页进页卡顿的主因（2026-11-01）。
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

	// ── 以下字段从 Raw 派生，不落库 ──────────────────────────
	// 书源管理界面需要按「是否有发现 / 是否需登录 / 响应时间 / 权重 / 类型」
	// 做筛选、排序与徽标展示，这些值都在原始 JSON 里。派生值随列表一起下发，
	// 前端就不必为每个源各拉一次完整 Raw（上千源时那是几十 MB）。
	// 派生规则见 domain.ParseSourceMeta，默认值与 Legado 原生实体一致。
	Type            int    `json:"type"`             // 0 文本 / 1 音频 / 2 图片 / 3 文件
	EnabledExplore  bool   `json:"enabledExplore"`   // 是否在发现页展示
	HasExploreURL   bool   `json:"hasExploreUrl"`    // 是否配置了 exploreUrl
	HasLoginURL     bool   `json:"hasLoginUrl"`      // 是否配置了 loginUrl
	EnabledCookie   bool   `json:"enabledCookieJar"` // 是否自动保存 Cookie
	Weight          int    `json:"weight"`           // 智能排序权重
	RespondTime     int64  `json:"respondTime"`      // 响应时间（毫秒）
	VariableComment string `json:"variableComment"`  // 源变量说明
}

// NewSourceView 从领域实体转换书源视图（含 Raw，仅限单条接口使用）。
func NewSourceView(s *domain.BookSource) SourceView {
	v := NewSourceBriefView(s)
	v.Raw = s.Raw
	return v
}

// NewSourceBriefView 转换列表用的精简书源视图（不含 Raw）。
func NewSourceBriefView(s *domain.BookSource) SourceView {
	var last *time.Time
	if !s.LastUpdateAt.IsZero() {
		t := s.LastUpdateAt
		last = &t
	}
	meta := s.Meta()
	return SourceView{
		ID:              s.ID,
		Name:            s.Name,
		Group:           s.Group,
		URL:             s.URL,
		Enabled:         s.Enabled,
		Order:           s.Order,
		Comment:         s.Comment,
		LastUpdateAt:    last,
		CreatedAt:       s.CreatedAt,
		Type:            meta.Type,
		EnabledExplore:  meta.EnabledExplore,
		HasExploreURL:   meta.HasExploreURL,
		HasLoginURL:     meta.HasLoginURL,
		EnabledCookie:   meta.EnabledCookie,
		Weight:          meta.Weight,
		RespondTime:     meta.RespondTime,
		VariableComment: meta.VariableComment,
	}
}

// SourceGroupView 是书源管理界面的一个分组条目。
//
// Count 是组内书源数量：分组菜单要显示「分组名 (12)」，
// 分组管理对话框也要靠它判断哪些组是空的。
type SourceGroupView struct {
	Name  string `json:"name"`
	Count int    `json:"count"`
}

// SourceVariableView 是「设置源变量」对话框的数据。
//
// 原生把源变量存在缓存里、书源实体不持久化；桌面端存在独立表
// （source_variables），按书源地址作为主键。
type SourceVariableView struct {
	SourceID int64  `json:"sourceId"`
	Name     string `json:"name"`
	URL      string `json:"url"`
	Variable string `json:"variable"`
	// Comment 是书源的 variableComment 字段（原生把它作为对话框提示文本），
	// 为空时前端显示一句通用说明。
	Comment string `json:"comment"`
}

// NewSourceGroupViews 转换分组列表。
func NewSourceGroupViews(in []domain.SourceGroup) []SourceGroupView {
	out := make([]SourceGroupView, 0, len(in))
	for _, g := range in {
		out = append(out, SourceGroupView{Name: g.Name, Count: g.Count})
	}
	return out
}

// NewSourceViews 批量转换书源视图（含 Raw，仅限单条语义的调用方）。
func NewSourceViews(sources []*domain.BookSource) []SourceView {
	out := make([]SourceView, 0, len(sources))
	for _, s := range sources {
		out = append(out, NewSourceView(s))
	}
	return out
}

// NewSourceBriefViews 批量转换精简书源视图（不含 Raw）——列表接口专用。
func NewSourceBriefViews(sources []*domain.BookSource) []SourceView {
	out := make([]SourceView, 0, len(sources))
	for _, s := range sources {
		out = append(out, NewSourceBriefView(s))
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
	// Variable 是书源在列表页 @put 出来的变量，加入书架时原样回传，
	// 目录/正文规则里的 @get 才能取到值。
	Variable string `json:"variable,omitempty"`
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
		Variable:    r.Variable,
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
// Paged 表示该分类地址里带 {{page}} / {{page-1}} 等分页变量——只有这时
// 「下一页」才有意义。桌面端据此决定是否显示翻页按钮，避免用户点了没反应。
type ExploreKindView struct {
	Title string `json:"title"`
	URL   string `json:"url"`
	Paged bool   `json:"paged"`
}

// NewExploreKindView 转换单个分类。
// 「是否支持翻页」由地址里有没有分页变量决定，与具体分类无关。
//
// 分页写法有三种（均为 AnalyzeUrl 引擎能力）：
//  1. `{{page}}` / `{{page-1}}` / `{{page*2}}` —— {{}} 内 JS 表达式可用 page 变量；
//  2. `<1,2,3>` 页码列表（pagePattern），翻页时按下标取值；
//  3. `{{pageNumber}}` 这类自定义变量不算分页变量。
//
// 注意：原版引擎没有 `@page` 约定（2026-11 核实），旧判定里的 `strings.Contains(url, "@page")`
// 属于误报来源，已移除。
func NewExploreKindView(k domain.ExploreKind) ExploreKindView {
	return ExploreKindView{
		Title: k.Title,
		URL:   k.URL,
		Paged: pageVarRe.MatchString(k.URL) || pageListRe.MatchString(k.URL),
	}
}

// pageVarRe 匹配 {{...}} 内含 page 整词的分页表达式：
// {{page}} / {{page-1}} / {{(page-1)*25}} / {{ page + 1 }} 都命中；
// {{pageNumber}} 等自定义变量因「page」后跟字母不成词边界而排除。
// 注意不能只认 `{{page` 前缀——`{{(page-1)*25}}` 的 {{ 后是括号（2026-11 实测踩坑）。
var pageVarRe = regexp.MustCompile(`\{\{[^{}]*\bpage\b`)

// pageListRe 匹配 <1,2,3> 页码列表写法。
var pageListRe = regexp.MustCompile(`<\d+\s*,\s*\d+[^<>]*>`)

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
