package rss

// Source 是订阅源的对外视图。
type Source struct {
	ID        int64  `json:"id"`
	Name      string `json:"name"`
	URL       string `json:"url"`
	Group     string `json:"group"`
	Enabled   bool   `json:"enabled"`
	SortOrder int    `json:"sortOrder"`
	// UnreadCount 由列表查询顺带聚合，UI 不必再为每个源发一次统计请求。
	UnreadCount int   `json:"unreadCount"`
	CreatedAt   int64 `json:"createdAt"`
	UpdatedAt   int64 `json:"updatedAt"`
}

// SourceInput 是新增/修改订阅源的入参。
//
// 用对象而不是长参数列表：源字段会随 UI 演进增加（分组、排序、规则），
// 位置参数一旦增删就会悄悄错位。id 为 0 表示新增。
type SourceInput struct {
	ID    int64  `json:"id"`
	Name  string `json:"name"`
	URL   string `json:"url"`
	Group string `json:"group"`
	// Enabled 用指针区分「未传」与「显式传 false」：
	// 新增时缺省为启用，修改时缺省保持原值。
	Enabled   *bool `json:"enabled,omitempty"`
	SortOrder int   `json:"sortOrder"`
}

// Article 是订阅文章的对外视图。
//
// Content 随列表返回：RSS 正文没有章节那样的独立数据面通道，
// 且单篇通常只有几十 KB，分两次请求反而更慢。
type Article struct {
	ID          int64  `json:"id"`
	SourceID    int64  `json:"sourceId"`
	SourceName  string `json:"sourceName"`
	Title       string `json:"title"`
	Link        string `json:"link"`
	Description string `json:"description"`
	Content     string `json:"content"`
	Author      string `json:"author"`
	// PubDate 是源站发布时间（Unix 秒）；解析失败时为 0，列表按 id 兜底排序。
	PubDate   int64 `json:"pubDate"`
	Read      bool  `json:"read"`
	Favorite  bool  `json:"favorite"`
	CreatedAt int64 `json:"createdAt"`
}

// RefreshResult 是一次拉取的统计。Errors 按源聚合，单个源失败不影响其他源。
type RefreshResult struct {
	SourceID int64    `json:"sourceId"`
	Sources  int      `json:"sources"`
	Added    int      `json:"added"`
	Updated  int      `json:"updated"`
	Skipped  int      `json:"skipped"`
	Errors   []string `json:"errors,omitempty"`
}
