package port

import (
	"context"
	"fmt"
	"strings"

	"github.com/legado/desktop/internal/domain"
)

// ChatMessage 是发给模型的一条消息。
type ChatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// ChatRequest 是一次对话补全请求。
//
// MaxTokens 为 0 表示不限制，交给服务端默认。
// Temperature 为 nil 表示不传给服务端，用其默认值——显式区分「不传」与「传 0」
// 是必要的，因为有些服务端把 temperature=0 当作必须显式开启的贪心解码。
type ChatRequest struct {
	Model       string
	Messages    []ChatMessage
	Temperature *float64
	MaxTokens   int
}

// ChatResponse 是一次对话补全结果。
type ChatResponse struct {
	Content string
	// Usage 可能为 0：相当一部分兼容服务不返回用量。
	PromptTokens     int
	CompletionTokens int
}

// AIErrorKind 对 AI 调用失败做分类，让上层能区分「该重试」与「该报给用户」。
type AIErrorKind string

const (
	// AIErrAuth 鉴权失败（401/403）——重试无意义，必须让用户改密钥。
	AIErrAuth AIErrorKind = "auth"
	// AIErrRate 限流（429）——值得退避重试。
	AIErrRate AIErrorKind = "rate"
	// AIErrServer 服务端错误（5xx）——值得重试。
	AIErrServer AIErrorKind = "server"
	// AIErrNetwork 网络不可达——值得重试。
	AIErrNetwork AIErrorKind = "network"
	// AIErrTimeout 请求超时——值得重试。
	AIErrTimeout AIErrorKind = "timeout"
	// AIErrBadRequest 请求被拒（400）——通常是上下文超窗或参数非法，重试无意义。
	AIErrBadRequest AIErrorKind = "bad_request"
	// AIErrProtocol 响应无法解析——服务端不兼容 OpenAI 协议。
	AIErrProtocol AIErrorKind = "protocol"
)

// AIError 是 AI 调用的结构化错误。
//
// 之所以不用裸 error：上层需要根据失败类型决定行为——限流要退避、
// 鉴权失败要提示改密钥、超窗要自动缩减上下文重试，靠字符串匹配不可靠。
type AIError struct {
	Kind    AIErrorKind
	Status  int
	Message string
}

// Error 实现 error。
func (e *AIError) Error() string {
	if e.Status > 0 {
		return fmt.Sprintf("AI 调用失败(%s, HTTP %d): %s", e.Kind, e.Status, e.Message)
	}
	return fmt.Sprintf("AI 调用失败(%s): %s", e.Kind, e.Message)
}

// Retryable 报告该错误是否值得重试。
func (e *AIError) Retryable() bool {
	switch e.Kind {
	case AIErrRate, AIErrServer, AIErrNetwork, AIErrTimeout:
		return true
	}
	return false
}

// IsContextOverflow 报告是否疑似上下文超出模型窗口。
//
// 各服务返回的提示文案五花八门，只能按关键词猜；猜错的最坏结果是
// 少做一次自动缩减重试，不会误伤正确性。
func (e *AIError) IsContextOverflow() bool {
	if e.Kind != AIErrBadRequest {
		return false
	}
	low := strings.ToLower(e.Message)
	for _, kw := range []string{
		"context length", "context_length", "maximum context",
		"too many tokens", "token limit", "超出", "上下文", "长度超限",
	} {
		if strings.Contains(low, kw) {
			return true
		}
	}
	return false
}

// LLMClient 是与大模型服务通信的端口。
//
// 放在 port 而非 adapter：app 层只面向接口编程，便于单测时用假实现替掉真实网络。
type LLMClient interface {
	// Chat 执行一次非流式补全。
	Chat(ctx context.Context, cfg domain.AIConfig, req ChatRequest) (ChatResponse, error)

	// ChatStream 执行流式补全，每收到一段文本就回调 onDelta。
	//
	// 回调返回 error 时立即中止请求（用于用户点了「停止」）。
	// 返回值为拼接后的完整结果与用量。
	ChatStream(ctx context.Context, cfg domain.AIConfig, req ChatRequest,
		onDelta func(delta string) error) (ChatResponse, error)

	// Embed 批量计算文本向量。返回顺序与输入一致。
	//
	// 批量而非单条：索引一本长书会有上千个切片，逐条调用的往返开销会
	// 成为主要耗时，且更容易触发限流。
	Embed(ctx context.Context, cfg domain.AIConfig, model string, inputs []string) ([][]float32, error)
}

// AIChunkRepository 持久化语义切片。
type AIChunkRepository interface {
	// PutBulk 批量写入切片（按 书+序号 覆盖）。
	PutBulk(ctx context.Context, chunks []*domain.AIChunk) error
	// UpdateEmbedding 只更新向量字段，用于「先落文本、后补向量」的两阶段索引。
	UpdateEmbedding(ctx context.Context, id int64, vec []float32, model string, dim int) error
	// List 返回某本书的全部切片，按序号升序，含向量。
	List(ctx context.Context, bookID int64) ([]*domain.AIChunk, error)
	// ListRange 返回指定序号区间的切片。
	ListRange(ctx context.Context, bookID int64, from, to int) ([]*domain.AIChunk, error)
	// Get 按主键取单条。
	Get(ctx context.Context, id int64) (*domain.AIChunk, error)
	// Count 返回切片总数。
	Count(ctx context.Context, bookID int64) (int, error)
	// CountWithVector 返回已具备向量的切片数，用于展示「有多少能参与语义检索」。
	CountWithVector(ctx context.Context, bookID int64) (int, error)
	// DeleteBeyond 删除序号大于 maxOrdinal 的切片。
	//
	// 重新索引时正文可能变短，旧的多余切片若不清掉，会被召回成「已删除的章节」。
	DeleteBeyond(ctx context.Context, bookID int64, maxOrdinal int) error
	// DeleteByBook 删除某本书的全部切片。
	DeleteByBook(ctx context.Context, bookID int64) error
	// DeleteByChapters 删除指定章节区间的切片（正文变更时局部重建）。
	DeleteByChapters(ctx context.Context, bookID int64, from, to int) error
}

// AISummaryRepository 持久化分层摘要。
type AISummaryRepository interface {
	// Put 写入或覆盖一条摘要（按 书+层级+序号 唯一）。
	Put(ctx context.Context, s *domain.AISummary) error
	// Level 返回某本书指定层级的全部摘要，按序号升序。
	Level(ctx context.Context, bookID int64, level int) ([]*domain.AISummary, error)
	// Top 返回某本书最高层级的摘要（通常只有一条，即全书摘要）。
	Top(ctx context.Context, bookID int64) (*domain.AISummary, error)
	// MaxLevel 返回已有摘要的最大层级；无摘要返回 0。
	MaxLevel(ctx context.Context, bookID int64) (int, error)
	// DeleteByBook 删除某本书的全部摘要。
	DeleteByBook(ctx context.Context, bookID int64) error
	// DeleteFromLevel 删除指定层级及其上层的摘要（下层变动后上层结论即失效）。
	DeleteFromLevel(ctx context.Context, bookID int64, level int) error
}

// AIIndexStateRepository 持久化索引进度。
type AIIndexStateRepository interface {
	// Get 取索引状态；不存在返回 domain.ErrNotFound。
	Get(ctx context.Context, bookID int64) (*domain.AIIndexState, error)
	// Put 写入或覆盖状态。
	Put(ctx context.Context, st *domain.AIIndexState) error
	// Delete 删除状态。
	Delete(ctx context.Context, bookID int64) error
}

// AIChatRepository 持久化问答会话与消息。
type AIChatRepository interface {
	// CreateChat 创建会话并回填 ID。
	CreateChat(ctx context.Context, c *domain.AIChat) error
	// GetChat 取会话；不存在返回 domain.ErrNotFound。
	GetChat(ctx context.Context, id int64) (*domain.AIChat, error)
	// ListChats 返回某本书的会话，按更新时间倒序。
	ListChats(ctx context.Context, bookID int64) ([]*domain.AIChat, error)
	// TouchChat 更新会话的更新时间（有新消息时）。
	TouchChat(ctx context.Context, id int64) error
	// DeleteChat 删除会话及其消息。
	DeleteChat(ctx context.Context, id int64) error
	// AddMessage 追加一条消息并回填 ID。
	AddMessage(ctx context.Context, m *domain.AIMessage) error
	// Messages 返回会话的全部消息，按 ID 升序。
	Messages(ctx context.Context, chatID int64) ([]*domain.AIMessage, error)
}
