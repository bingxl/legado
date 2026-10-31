package api

import (
	"context"

	"github.com/legado/desktop/internal/app/dto"
)

// AIAPI 暴露 AI 总结与基于书籍内容的问答能力。
type AIAPI struct {
	svc aiService
}

// aiService 是 AI 服务的能力契约。
//
// 与其它 API 一致：这里只声明当前绑定层用到的方法，
// 服务端实现多了不算错，少了编译不过。
type aiService interface {
	GetConfig(ctx context.Context) (dto.AIConfigView, error)
	SaveConfig(ctx context.Context, in dto.AIConfigInput) (dto.AIConfigView, error)
	TestConnection(ctx context.Context, in dto.AIConfigInput) (dto.AITestResult, error)

	StartIndex(ctx context.Context, bookID int64, scope string, from, to int) (dto.AIIndexStatusView, error)
	CancelIndex(ctx context.Context, bookID int64) error
	IndexStatus(ctx context.Context, bookID int64) (dto.AIIndexStatusView, error)
	DeleteIndex(ctx context.Context, bookID int64) error
	GetSummary(ctx context.Context, bookID int64) (dto.AISummaryView, error)
	SummarizeChapters(ctx context.Context, bookID int64, from, to int) (string, error)

	CreateChat(ctx context.Context, bookID int64, title string) (dto.AIChatView, error)
	ListChats(ctx context.Context, bookID int64) ([]dto.AIChatView, error)
	GetMessages(ctx context.Context, chatID int64) ([]dto.AIMessageView, error)
	DeleteChat(ctx context.Context, chatID int64) error
	Ask(ctx context.Context, chatID int64, question string) error
	StopAnswer(ctx context.Context, chatID int64) error
}

// NewAIAPI 创建 AI 绑定服务。
func NewAIAPI(svc aiService) *AIAPI {
	return &AIAPI{svc: svc}
}

// GetConfig 读取 AI 配置（不含密钥明文）。
func (a *AIAPI) GetConfig() (dto.AIConfigView, error) {
	return a.svc.GetConfig(newCtx())
}

// SaveConfig 保存 AI 配置。APIKey 传空串表示保持原密钥不变。
func (a *AIAPI) SaveConfig(in dto.AIConfigInput) (dto.AIConfigView, error) {
	return a.svc.SaveConfig(newCtx(), in)
}

// TestConnection 用给定配置（无需先保存）探测连通性。
func (a *AIAPI) TestConnection(in dto.AIConfigInput) (dto.AITestResult, error) {
	return a.svc.TestConnection(newCtx(), in)
}

// StartIndex 启动一本书的索引任务。
//
// scope 取 all / read / range；range 时才需要 from/to。方法立即返回，
// 进度通过 ai:index:progress 事件推送——整本索引可能几十分钟，
// 同步等待会让前端界面卡死且无法取消。
func (a *AIAPI) StartIndex(bookID int64, scope string, from, to int) (dto.AIIndexStatusView, error) {
	return a.svc.StartIndex(newCtx(), bookID, scope, from, to)
}

// CancelIndex 取消正在进行的索引任务。
func (a *AIAPI) CancelIndex(bookID int64) error {
	return a.svc.CancelIndex(newCtx(), bookID)
}

// IndexStatus 查询某本书的索引状态。
func (a *AIAPI) IndexStatus(bookID int64) (dto.AIIndexStatusView, error) {
	return a.svc.IndexStatus(newCtx(), bookID)
}

// DeleteIndex 删除某本书的全部索引数据。
func (a *AIAPI) DeleteIndex(bookID int64) error {
	return a.svc.DeleteIndex(newCtx(), bookID)
}

// GetSummary 读取已生成的全书摘要。
func (a *AIAPI) GetSummary(bookID int64) (dto.AISummaryView, error) {
	return a.svc.GetSummary(newCtx(), bookID)
}

// SummarizeChapters 对指定章节区间生成摘要，不建立完整索引。
func (a *AIAPI) SummarizeChapters(bookID int64, from, to int) (string, error) {
	return a.svc.SummarizeChapters(newCtx(), bookID, from, to)
}

// CreateChat 新建一个问答会话。
func (a *AIAPI) CreateChat(bookID int64, title string) (dto.AIChatView, error) {
	return a.svc.CreateChat(newCtx(), bookID, title)
}

// ListChats 返回某本书的历史会话。
func (a *AIAPI) ListChats(bookID int64) ([]dto.AIChatView, error) {
	return a.svc.ListChats(newCtx(), bookID)
}

// GetMessages 返回某会话的全部消息。
func (a *AIAPI) GetMessages(chatID int64) ([]dto.AIMessageView, error) {
	return a.svc.GetMessages(newCtx(), chatID)
}

// DeleteChat 删除会话及其消息。
func (a *AIAPI) DeleteChat(chatID int64) error {
	return a.svc.DeleteChat(newCtx(), chatID)
}

// Ask 发起提问并立即返回。
//
// 回答内容不通过返回值给出，而是走两个事件：ai:answer:chunk 逐段到达，
// ai:answer:done 带完整正文与引用结束。SSE 是边生成边到达的，
// 同步等待会让前端一分钟看不到任何东西且无法停止。
func (a *AIAPI) Ask(chatID int64, question string) error {
	return a.svc.Ask(newCtx(), chatID, question)
}

// StopAnswer 停止某会话正在生成的回答。
func (a *AIAPI) StopAnswer(chatID int64) error {
	return a.svc.StopAnswer(newCtx(), chatID)
}
