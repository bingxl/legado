package domain

import (
	"strings"
	"time"
)

// AIConfig 是 AI 总结与问答功能的连接配置。
//
// 设计要点：embedding 的通道**独立于** chat 通道。原因是相当一部分
// OpenAI 兼容服务商只提供 chat 而不提供 embedding（DeepSeek、Moonshot 即如此），
// 若把两者绑死，用户配了这些服务后整个检索能力就没了。
// Embedding 留空时由应用层降级为关键词召回，功能不残废。
type AIConfig struct {
	// BaseURL 形如 https://api.deepseek.com/v1，不含结尾斜杠。
	BaseURL string `json:"baseURL"`
	APIKey  string `json:"apiKey"`
	Model   string `json:"model"`
	// Temperature 为 0 表示未设置，由适配器落到默认值。
	Temperature float64 `json:"temperature"`
	// ContextWindow 是模型上下文上限（token）。0 表示未知，由适配器按模型名推断。
	ContextWindow int `json:"contextWindow"`

	// EmbeddingBaseURL 留空表示复用 BaseURL。
	EmbeddingBaseURL string `json:"embeddingBaseURL"`
	EmbeddingModel   string `json:"embeddingModel"`
	// EmbeddingDim 为 0 时首次调用后按返回值回填。
	EmbeddingDim int `json:"embeddingDim"`

	// MaxConcurrent 是摘要生成阶段的并发度，<=0 时取默认值。
	MaxConcurrent int `json:"maxConcurrent"`
}

// ChatEndpoint 返回 chat 调用的基础地址。
func (c *AIConfig) ChatEndpoint() string { return strings.TrimRight(c.BaseURL, "/") }

// EmbeddingEndpoint 返回 embedding 调用的基础地址。
func (c *AIConfig) EmbeddingEndpoint() string {
	if strings.TrimSpace(c.EmbeddingBaseURL) != "" {
		return strings.TrimRight(c.EmbeddingBaseURL, "/")
	}
	return c.ChatEndpoint()
}

// HasEmbedding 报告是否配置了可用的 embedding 通道。
//
// 没有 embedding 时问答仍可进行，只是召回退化为关键词匹配。
func (c *AIConfig) HasEmbedding() bool {
	return strings.TrimSpace(c.EmbeddingModel) != "" && c.EmbeddingEndpoint() != ""
}

// Configured 报告 chat 通道是否具备最低限度的可用信息。
func (c *AIConfig) Configured() bool {
	return strings.TrimSpace(c.BaseURL) != "" && strings.TrimSpace(c.Model) != ""
}

// AIChunk 是一段被索引的原文切片，是向量检索与引用溯源的粒度。
//
// 之所以单独存切片而不是按章存：一本书的章节长度差异极大（几百字到几万字），
// 按章检索会召回大量无关内容，按固定 token 预算切片才能让召回粒度稳定。
type AIChunk struct {
	ID         int64
	BookID     int64
	ChapterIdx int
	// Ordinal 是书内全局序号，保证多章拼接后仍能还原阅读顺序。
	Ordinal    int
	CharStart  int // 在章节纯文本内的起始偏移，用于阅读器高亮定位
	CharEnd    int
	Title      string // 所属章节标题，引用展示用
	Text       string
	TokenCount int
	// SrcHash 是源文本的哈希。正文变了才需要重算向量，避免重复花钱。
	SrcHash   string
	Embedding []float32
	EmbModel  string
	EmbDim    int
	CreatedAt time.Time
}

// HasVector 报告该切片是否已具备可参与检索的向量。
func (c *AIChunk) HasVector() bool { return len(c.Embedding) > 0 }

// AISummary 是分层摘要中的一条。
//
// Level 从 1 起：1 = 由原文切片合并出的段摘要，2 及以上 = 由下层摘要再合并，
// 最高层（每层仅一条时）即全书摘要。
type AISummary struct {
	ID          int64
	BookID      int64
	Level       int
	Ordinal     int
	ParentLevel int // 0 表示无父（顶层）
	ParentOrd   int
	ChapterFrom int // -1 表示不适用（跨章节合并后无明确边界）
	ChapterTo   int
	Content     string
	TokenCount  int
	Model       string
	SrcHash     string
	OK          bool
	Error       string
	CreatedAt   time.Time
	UpdatedAt   time.Time
}

// AIIndexState 记录一本书的索引进度，是断点续跑的依据。
//
// 索引一本长书可能耗时几十分钟且要花钱，中途取消或崩溃后必须能接着算，
// 因此目标范围与计数都要落库，而不是只留在内存里。
type AIIndexState struct {
	BookID       int64
	Scope        string // all | read | range
	ChapterFrom  int
	ChapterTo    int
	Status       string // idle | running | done | failed | canceled
	ChunkCount   int
	EmbDone      int
	SummaryDone  int
	SummaryTotal int
	Error        string
	UpdatedAt    time.Time
}

// 索引状态取值。
const (
	AIIndexIdle     = "idle"
	AIIndexRunning  = "running"
	AIIndexDone     = "done"
	AIIndexFailed   = "failed"
	AIIndexCanceled = "canceled"
)

// AIIndexScope 是索引范围取值。
const (
	AIScopeAll   = "all"
	AIScopeRead  = "read"
	AIScopeRange = "range"
)

// AIChat 是与某本书绑定的一次问答会话。
type AIChat struct {
	ID        int64
	BookID    int64
	Title     string
	Scope     string
	Model     string
	CreatedAt time.Time
	UpdatedAt time.Time
}

// AIMessage 是会话中的一条消息。
type AIMessage struct {
	ID        int64
	ChatID    int64
	Role      string // user | assistant
	Content   string
	Refs      []AIRef
	CreatedAt time.Time
}

// AIRole 是消息角色取值。
const (
	AIRoleUser      = "user"
	AIRoleAssistant = "assistant"
	AIRoleSystem    = "system"
)

// AIRef 是回答引用到的原文切片，让前端能跳转并高亮出处。
//
// 这是「基于书籍问答」区别于通用聊天的关键：回答必须可溯源，
// 否则用户无法判断模型是在复述原文还是在编造。
type AIRef struct {
	ChunkID    int64   `json:"chunkId"`
	ChapterIdx int     `json:"chapterIdx"`
	Title      string  `json:"title"`
	Score      float64 `json:"score"`
	Excerpt    string  `json:"excerpt"`
}
