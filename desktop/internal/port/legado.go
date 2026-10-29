package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// CheckItems 指定书源校验时需要检查的项目。
type CheckItems struct {
	Search  bool // 搜索
	Info    bool // 书籍详情
	TOC     bool // 目录
	Content bool // 正文
}

// CheckAll 返回一个检查全部项目的 CheckItems。
func CheckAll() CheckItems { return CheckItems{Search: true, Info: true, TOC: true, Content: true} }

// NeedNetwork 报告是否需要发起网络请求。
// 全部为 false 时只需做静态规则校验，不必联网。
func (c CheckItems) NeedNetwork() bool {
	return c.Search || c.Info || c.TOC || c.Content
}

// IssueLevel 表示校验问题的严重程度。
type IssueLevel string

const (
	IssueLevelError   IssueLevel = "error"   // 阻断可用性
	IssueLevelWarning IssueLevel = "warning" // 可能影响部分功能
	IssueLevelInfo    IssueLevel = "info"    // 提示性信息
)

// ValidationIssue 是书源校验发现的一个问题。
type ValidationIssue struct {
	Level   IssueLevel `json:"level"`
	Field   string     `json:"field"`   // 相关字段，可为空
	Message string     `json:"message"` // 面向用户的中文描述
}

// SourceFetcher 屏蔽底层书源引擎（legado-go）的实现细节，
// 使 app 层只与领域类型打交道，不被第三方模型污染。
type SourceFetcher interface {
	// Search 在单个书源内搜索关键词，page 从 1 开始。
	Search(ctx context.Context, src *domain.BookSource, keyword string, page int) ([]*domain.SearchResult, error)
	// Explore 拉取发现页（书源内的分类/榜单），url 为空时使用书源默认发现地址。
	Explore(ctx context.Context, src *domain.BookSource, url string, page int) ([]*domain.SearchResult, error)
	// ExploreKinds 解析书源声明的发现分类。纯本地解析，不发起网络请求。
	// 返回空切片表示该源不支持发现（只能搜索）。
	ExploreKinds(ctx context.Context, src *domain.BookSource) ([]domain.ExploreKind, error)
	// HasExplore 报告书源是否声明了发现地址。
	//
	// 这是不解码规则、不联网的字段判断，专供发现页筛源用：
	// 用户展开某个源之前，没有任何必要去解析它的分类规则。
	HasExplore(src *domain.BookSource) bool
	// GetBookInfo 拉取书籍详情与目录。返回的 Book 已补全元数据。
	GetBookInfo(ctx context.Context, src *domain.BookSource, b *domain.Book) (*domain.Book, []*domain.BookChapter, error)
	// GetContent 抓取指定章节正文。
	// nextChapterURL 是下一章的地址，用来给书源的「正文下一页」规则踩刹车：
	// 部分源的 nextContentUrl 会误选中「下一章」链接，撞上它就必须停下，
	// 否则下一章正文会被拼到本章末尾。未知时传空串。
	GetContent(ctx context.Context, src *domain.BookSource, b *domain.Book, ch *domain.BookChapter, nextChapterURL string) (*ChapterContent, error)
	// Validate 校验书源规则，items 指定检查范围。
	Validate(ctx context.Context, src *domain.BookSource, items CheckItems) ([]ValidationIssue, error)
}
