package dto

import (
	"time"

	"github.com/legado/desktop/internal/domain"
)

// ReplaceRuleView 是替换规则在管理界面上的视图。
//
// 与书源同理：Raw 保留规则原文 JSON，前端既可以直接编辑，
// 也可以用结构化表单编辑 Name/Group/Enabled。
// ReplaceRuleView 是替换规则在管理界面上的视图。
//
// 与书源同理：Raw 保留规则原文 JSON，前端既可以直接编辑，
// 也可以用结构化表单编辑 Name/Group/Enabled。
//
// 不带创建时间：replace_rules 表没有记录它，硬塞一个零值反而会让前端
// 显示成 1970 年，不如不给。
type ReplaceRuleView struct {
	ID      int64  `json:"id"`
	Name    string `json:"name"`
	Group   string `json:"group"`
	Enabled bool   `json:"enabled"`
	Order   int    `json:"order"`
	Raw     string `json:"raw"`
}

// NewReplaceRuleView 从领域实体转换替换规则视图。
func NewReplaceRuleView(r *domain.ReplaceRule) ReplaceRuleView {
	return ReplaceRuleView{
		ID:      r.ID,
		Name:    r.Name,
		Group:   r.Group,
		Enabled: r.Enabled,
		Order:   r.Order,
		Raw:     r.Raw,
	}
}

// NewReplaceRuleViews 批量转换替换规则视图。
func NewReplaceRuleViews(rules []*domain.ReplaceRule) []ReplaceRuleView {
	out := make([]ReplaceRuleView, 0, len(rules))
	for _, r := range rules {
		out = append(out, NewReplaceRuleView(r))
	}
	return out
}

// ReplaceRuleImportResult 汇报一次替换规则导入的结果。
type ReplaceRuleImportResult struct {
	Imported int                 `json:"imported"` // 新增条数
	Updated  int                 `json:"updated"`  // 覆盖更新条数
	Skipped  int                 `json:"skipped"`  // 重复跳过条数
	Rules    []ReplaceRuleView   `json:"rules"`    // 受影响规则的最终状态
	Failures []ImportRuleFailure `json:"failures"` // 解析失败的条目
}

// ImportRuleFailure 描述一条导入失败的规则。
type ImportRuleFailure struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
}

// SubscriptionView 是书源订阅在管理界面上的视图。
type SubscriptionView struct {
	ID         int64      `json:"id"`
	Name       string     `json:"name"`
	URL        string     `json:"url"`
	Enabled    bool       `json:"enabled"`
	Order      int        `json:"order"`
	LastSyncAt *time.Time `json:"lastSyncAt"`
	CreatedAt  time.Time  `json:"createdAt"`
}

// NewSubscriptionView 从领域实体转换订阅视图。
func NewSubscriptionView(s *domain.SourceSubscription) SubscriptionView {
	var last *time.Time
	if !s.LastSyncAt.IsZero() {
		t := s.LastSyncAt
		last = &t
	}
	return SubscriptionView{
		ID:         s.ID,
		Name:       s.Name,
		URL:        s.URL,
		Enabled:    s.Enabled,
		Order:      s.Order,
		LastSyncAt: last,
		CreatedAt:  s.CreatedAt,
	}
}

// NewSubscriptionViews 批量转换订阅视图。
func NewSubscriptionViews(subs []*domain.SourceSubscription) []SubscriptionView {
	out := make([]SubscriptionView, 0, len(subs))
	for _, s := range subs {
		out = append(out, NewSubscriptionView(s))
	}
	return out
}

// SubscriptionSyncResult 汇报单个订阅的一次刷新结果。
//
// 与 SourceImportResult 分开定义是必要的：批量刷新要一次返回多个订阅的结果，
// 每个都要带上自己的订阅名，否则前端无法把失败归因到具体订阅。
type SubscriptionSyncResult struct {
	SubscriptionID   int64  `json:"subscriptionId"`
	SubscriptionName string `json:"subscriptionName"`
	Imported         int    `json:"imported"` // 新增书源数
	Updated          int    `json:"updated"`  // 更新书源数
	Failed           int    `json:"failed"`   // 解析失败条数
	Error            string `json:"error"`    // 订阅整体失败时的原因（网络/HTTP 错误）
}
