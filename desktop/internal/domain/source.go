package domain

import "time"

// BookSource 表示一个书源。
//
// 设计要点（详见 ARCHITECTURE.md 6.1）：书源字段数量庞大且随 Legado 上游演进，
// 因此这里**不做全字段 ORM 映射**，而是以 Raw 保存书源 JSON 原文，
// 仅将管理必需的字段提升为独立列以支持查询、分组与排序。
//
// 这样做的收益：
//  1. 与 Legado 生态完全兼容——导入导出就是 JSON 数组，无需字段对齐；
//  2. 上游新增字段时无需迁移表结构；
//  3. 抓取时由 adapter/legado 将 Raw 反序列化为引擎所需的模型。
type BookSource struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`    // 书源名称
	Group   string `json:"group"`   // 书源分组
	URL     string `json:"url"`     // 书源唯一标识（BookSourceUrl）
	Enabled bool   `json:"enabled"` // 是否启用
	Order   int    `json:"order"`   // 排序号
	Comment string `json:"comment"` // 用户备注

	// Raw 是书源的原始 JSON，与 Legado 书源格式保持一致。
	Raw string `json:"raw"`

	LastUpdateAt time.Time `json:"lastUpdateAt"` // 最近一次校验/更新的时间
	CreatedAt    time.Time `json:"createdAt"`
}

// ExploreKind 是书源声明的「发现」分类入口（对应 Legado 的 exploreUrl）。
//
// 与搜索的区别：搜索需要关键词，发现不需要——书源直接给出榜单/分类页地址，
// 用户点分类就能浏览站点推荐的书。因此「有 exploreUrl 的源」在 UI 上要单独
// 汇总展示，这也是筛选可用书源最直观的方式。
type ExploreKind struct {
	Title string `json:"title"` // 分类名，为空时由上层兜底
	URL   string `json:"url"`   // 分类页地址，可含 {{page}} 分页变量
}

// SourceSubscription 表示一个书源订阅源，可定期拉取远程书源集合。
type SourceSubscription struct {
	ID         int64     `json:"id"`
	Name       string    `json:"name"`
	URL        string    `json:"url"`
	Enabled    bool      `json:"enabled"`
	Order      int       `json:"order"`
	LastSyncAt time.Time `json:"lastSyncAt"`
	CreatedAt  time.Time `json:"createdAt"`
}

// ReplaceRule 是全局正文替换/净化规则。
// 与书源同理，以 Raw 保存原始 JSON，避免字段映射漂移。
type ReplaceRule struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Group   string `json:"group"`
	Enabled bool   `json:"enabled"`
	Order   int    `json:"order"`
	Raw     string `json:"raw"`
}

// TxtTocRule 是从 TXT 正文中提取目录的正则规则。
type TxtTocRule struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Rule    string `json:"rule"` // 目录行匹配的正则
	Enabled bool   `json:"enabled"`
	Order   int    `json:"order"`
}
