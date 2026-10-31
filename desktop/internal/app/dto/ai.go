package dto

import (
	"strings"
	"time"

	"github.com/legado/desktop/internal/domain"
)

// AIConfigView 是返回给前端的 AI 配置视图。
//
// 安全约定：apiKey **永不返回**前端，仅以 HasKey 指示是否已设置，
// KeyHint 给一个末位提示（便于用户确认「填的是哪把钥匙」）。
// 与 WebDAV 的密码处理保持一致。
type AIConfigView struct {
	BaseURL          string  `json:"baseURL"`
	Model            string  `json:"model"`
	HasKey           bool    `json:"hasKey"`
	KeyHint          string  `json:"keyHint"`
	Temperature      float64 `json:"temperature"`
	ContextWindow    int     `json:"contextWindow"`
	EmbeddingBaseURL string  `json:"embeddingBaseURL"`
	EmbeddingModel   string  `json:"embeddingModel"`
	EmbeddingDim     int     `json:"embeddingDim"`
	MaxConcurrent    int     `json:"maxConcurrent"`
	// Configured 表示对话通道已具备可用信息。
	Configured bool `json:"configured"`
	// EmbeddingReady 表示向量通道可用；为 false 时检索降级为关键词匹配。
	EmbeddingReady bool `json:"embeddingReady"`
}

// NewAIConfigView 从领域配置构造视图，剥离密钥。
func NewAIConfigView(c *domain.AIConfig) AIConfigView {
	if c == nil {
		return AIConfigView{}
	}
	return AIConfigView{
		BaseURL:          c.BaseURL,
		Model:            c.Model,
		HasKey:           c.APIKey != "",
		KeyHint:          maskKey(c.APIKey),
		Temperature:      c.Temperature,
		ContextWindow:    c.ContextWindow,
		EmbeddingBaseURL: c.EmbeddingBaseURL,
		EmbeddingModel:   c.EmbeddingModel,
		EmbeddingDim:     c.EmbeddingDim,
		MaxConcurrent:    c.MaxConcurrent,
		Configured:       c.Configured(),
		EmbeddingReady:   c.HasEmbedding(),
	}
}

// maskKey 只露末 4 位。
//
// 太短的密钥不露任何位：露 4 位对 8 位的串等于泄露一半。
func maskKey(key string) string {
	if key == "" {
		return ""
	}
	if len(key) < 12 {
		return "••••"
	}
	return "••••" + key[len(key)-4:]
}

// AIConfigInput 是保存配置与测试连接共用的入参。
type AIConfigInput struct {
	BaseURL string `json:"baseURL"`
	Model   string `json:"model"`
	// APIKey 为空表示「保持已存的密钥不变」，这是前端掩码展示下的必然约定。
	APIKey string `json:"apiKey"`
	// ClearKey 为真时显式清空密钥（用户要换服务商）。
	ClearKey         bool    `json:"clearKey"`
	Temperature      float64 `json:"temperature"`
	ContextWindow    int     `json:"contextWindow"`
	EmbeddingBaseURL string  `json:"embeddingBaseURL"`
	EmbeddingModel   string  `json:"embeddingModel"`
	EmbeddingDim     int     `json:"embeddingDim"`
	MaxConcurrent    int     `json:"maxConcurrent"`
}

// AIConfigPatch 把入参合并到已有配置上，返回新配置（不修改入参）。
//
// 抽成独立函数是因为保存与测试连接必须用同一套合并规则；
// 两处各写一遍迟早会分叉，表现为「保存后能用的配置一测试就失败」。
func AIConfigPatch(base *domain.AIConfig, in AIConfigInput) domain.AIConfig {
	out := domain.AIConfig{}
	if base != nil {
		out = *base
	}

	out.BaseURL = strings.TrimSpace(in.BaseURL)
	out.Model = strings.TrimSpace(in.Model)
	out.Temperature = in.Temperature
	out.ContextWindow = in.ContextWindow
	out.EmbeddingBaseURL = strings.TrimSpace(in.EmbeddingBaseURL)
	out.EmbeddingModel = strings.TrimSpace(in.EmbeddingModel)
	out.EmbeddingDim = in.EmbeddingDim
	out.MaxConcurrent = in.MaxConcurrent

	switch {
	case in.ClearKey:
		out.APIKey = ""
	case strings.TrimSpace(in.APIKey) != "":
		out.APIKey = strings.TrimSpace(in.APIKey)
		// 未显式传：沿用 base 里的密钥
	}
	return out
}

// AITestResult 是连接测试结果。
//
// 对话失败是致命问题（直接返回 error）；向量失败不致命——降级为关键词召回
// 后功能仍可用，因此放进结果里让前端提示而非阻断。
type AITestResult struct {
	ChatOK           bool   `json:"chatOk"`
	ChatReply        string `json:"chatReply"`
	EmbeddingOK      bool   `json:"embeddingOk"`
	EmbeddingDim     int    `json:"embeddingDim"`
	EmbeddingMessage string `json:"embeddingMessage"`
}

// AIIndexStatusView 是某本书的索引状态视图。
type AIIndexStatusView struct {
	BookID      int64  `json:"bookId"`
	Scope       string `json:"scope"`
	ChapterFrom int    `json:"chapterFrom"`
	ChapterTo   int    `json:"chapterTo"`
	Status      string `json:"status"`
	ChunkCount  int    `json:"chunkCount"`
	// VectorCount 已向量化的切片数；为 0 表示只能靠关键词召回。
	VectorCount  int `json:"vectorCount"`
	SummaryDone  int `json:"summaryDone"`
	SummaryTotal int `json:"summaryTotal"`
	// HasSummary 表示已生成全书摘要。
	HasSummary bool   `json:"hasSummary"`
	Summary    string `json:"summary"`
	Error      string `json:"error"`
	// UpdatedAt 为空表示从未索引过。
	UpdatedAt *time.Time `json:"updatedAt"`
}

// AIIndexProgress 是索引进度事件（event: ai:index:progress）。
type AIIndexProgress struct {
	BookID int64  `json:"bookId"`
	Phase  string `json:"phase"` // fetch | chunk | embed | summary | done | failed | canceled
	Done   int    `json:"done"`
	Total  int    `json:"total"`
	// Message 是可选的补充说明，例如「正在抓取第 12/340 章」。
	Message string `json:"message"`
	// Seq 是进程内单调递增的事件序号。事件经前端运行时异步投递，
	// 不保证按产生顺序到达；没有序号时，终态之后迟到的早阶段事件
	// 会把界面从「已就绪」打回「进行中」。前端据此丢弃过期事件。
	Seq int64 `json:"seq"`
}

// AIIndexPhase 取值。
const (
	AIPhaseFetch    = "fetch"
	AIPhaseChunk    = "chunk"
	AIPhaseEmbed    = "embed"
	AIPhaseSummary  = "summary"
	AIPhaseDone     = "done"
	AIPhaseFailed   = "failed"
	AIPhaseCanceled = "canceled"
)

// AISummaryView 是已生成摘要的视图。
type AISummaryView struct {
	Content     string `json:"content"`
	Level       int    `json:"level"`
	Model       string `json:"model"`
	ChapterFrom int    `json:"chapterFrom"`
	ChapterTo   int    `json:"chapterTo"`
	// UpdatedAt 为空表示尚无摘要。
	UpdatedAt *time.Time `json:"updatedAt"`
}

// NewAISummaryView 从领域摘要构造视图。
func NewAISummaryView(s *domain.AISummary) AISummaryView {
	if s == nil {
		return AISummaryView{}
	}
	t := s.UpdatedAt
	return AISummaryView{
		Content:     s.Content,
		Level:       s.Level,
		Model:       s.Model,
		ChapterFrom: s.ChapterFrom,
		ChapterTo:   s.ChapterTo,
		UpdatedAt:   &t,
	}
}

// ── 问答会话 ────────────────────────────────────────────────

// AIChatView 是一次问答会话。
type AIChatView struct {
	ID      int64  `json:"id"`
	BookID  int64  `json:"bookId"`
	Title   string `json:"title"`
	Scope   string `json:"scope"`
	Model   string `json:"model"`
	Updated string `json:"updatedAt"`
}

// NewAIChatView 从领域会话构造视图。
func NewAIChatView(c *domain.AIChat) AIChatView {
	if c == nil {
		return AIChatView{}
	}
	return AIChatView{
		ID:      c.ID,
		BookID:  c.BookID,
		Title:   c.Title,
		Scope:   c.Scope,
		Model:   c.Model,
		Updated: c.UpdatedAt.Format(time.RFC3339),
	}
}

// AIRefView 是回答引用的一条出处。
//
// 用独立视图而不是直接返回 domain.AIRef：领域实体不得外泄到前端
// （见 ARCHITECTURE.md R4），否则改一个字段名就会连带改动前端契约。
type AIRefView struct {
	ChunkID    int64   `json:"chunkId"`
	ChapterIdx int     `json:"chapterIdx"`
	Title      string  `json:"title"`
	Score      float64 `json:"score"`
	Excerpt    string  `json:"excerpt"`
}

// NewAIRefViews 批量转换引用。
func NewAIRefViews(refs []domain.AIRef) []AIRefView {
	out := make([]AIRefView, 0, len(refs))
	for _, r := range refs {
		out = append(out, AIRefView{
			ChunkID:    r.ChunkID,
			ChapterIdx: r.ChapterIdx,
			Title:      r.Title,
			Score:      r.Score,
			Excerpt:    r.Excerpt,
		})
	}
	return out
}

// AIMessageView 是会话里的一条消息。
type AIMessageView struct {
	ID        int64       `json:"id"`
	ChatID    int64       `json:"chatId"`
	Role      string      `json:"role"`
	Content   string      `json:"content"`
	Refs      []AIRefView `json:"refs"`
	CreatedAt string      `json:"createdAt"`
}

// NewAIMessageView 从领域消息构造视图。
func NewAIMessageView(m *domain.AIMessage) AIMessageView {
	if m == nil {
		return AIMessageView{}
	}
	return AIMessageView{
		ID:        m.ID,
		ChatID:    m.ChatID,
		Role:      m.Role,
		Content:   m.Content,
		Refs:      NewAIRefViews(m.Refs),
		CreatedAt: m.CreatedAt.Format(time.RFC3339),
	}
}

// AIAnswerChunk 是流式回答的一个分片（event: ai:answer:chunk）。
type AIAnswerChunk struct {
	ChatID int64  `json:"chatId"`
	BookID int64  `json:"bookId"`
	Delta  string `json:"delta"`
	// Seq 从 1 起严格递增，前端据此丢弃重复或乱序的分片。
	Seq int `json:"seq"`
}

// 回答结束状态取值。
const (
	AIAnswerStateDone     = "done"
	AIAnswerStateCanceled = "canceled"
	AIAnswerStateFailed   = "failed"
)

// AIAnswerDone 是一次流式回答的结束事件（event: ai:answer:done）。
//
// 带上完整正文而不只是「结束了」：前端可能因页面切换丢了中间分片，
// 用最终整段兜底，避免界面上的回答残缺。
type AIAnswerDone struct {
	ChatID  int64       `json:"chatId"`
	BookID  int64       `json:"bookId"`
	State   string      `json:"state"`
	Content string      `json:"content"`
	Refs    []AIRefView `json:"refs"`
	Error   string      `json:"error"`
	// Note 是降级说明（例如「未配置向量模型，正在用关键词匹配」）。
	Note string `json:"note"`
}
