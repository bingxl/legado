package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// 流式输出的节流参数。
//
// 每个 token 都发一次事件会造成 IPC 风暴（一次回答上千次跨进程调用），
// 而前端打字机效果只需要每帧有一批新字符。60ms 约等于 16fps，够顺滑。
const (
	aiAnswerThrottle   = 60 * time.Millisecond
	aiAnswerFlushRunes = 120
)

// 带多少轮历史进上下文。
//
// 只带最近几条：多轮对话里越早的内容越无关，全带上会挤掉检索到的原文，
// 反而让回答质量下降。
const aiHistoryMessages = 8

// ── 会话管理 ────────────────────────────────────────────────

// CreateChat 新建一个问答会话。
func (s *AIService) CreateChat(ctx context.Context, bookID int64, title string) (dto.AIChatView, error) {
	if bookID == 0 {
		return dto.AIChatView{}, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if s.chats == nil {
		return dto.AIChatView{}, fmt.Errorf("%w: 会话存储未就绪", domain.ErrNotConfigured)
	}
	cfg, err := s.config(ctx)
	if err != nil && !errors.Is(err, domain.ErrNotConfigured) {
		return dto.AIChatView{}, err
	}
	title = strings.TrimSpace(title)
	if title == "" {
		title = "新的对话"
	}
	chat := &domain.AIChat{BookID: bookID, Title: title, Scope: domain.AIScopeAll}
	if cfg != nil {
		chat.Model = cfg.Model
	}
	if err := s.chats.CreateChat(ctx, chat); err != nil {
		return dto.AIChatView{}, err
	}
	return dto.NewAIChatView(chat), nil
}

// ListChats 返回某本书的历史会话。
func (s *AIService) ListChats(ctx context.Context, bookID int64) ([]dto.AIChatView, error) {
	if bookID == 0 {
		return nil, fmt.Errorf("%w: 缺少书籍 ID", domain.ErrInvalidArgument)
	}
	if s.chats == nil {
		return nil, fmt.Errorf("%w: 会话存储未就绪", domain.ErrNotConfigured)
	}
	list, err := s.chats.ListChats(ctx, bookID)
	if err != nil {
		return nil, err
	}
	out := make([]dto.AIChatView, 0, len(list))
	for _, c := range list {
		out = append(out, dto.NewAIChatView(c))
	}
	return out, nil
}

// GetMessages 返回会话的全部消息。
func (s *AIService) GetMessages(ctx context.Context, chatID int64) ([]dto.AIMessageView, error) {
	if chatID == 0 {
		return nil, fmt.Errorf("%w: 缺少会话 ID", domain.ErrInvalidArgument)
	}
	if s.chats == nil {
		return nil, fmt.Errorf("%w: 会话存储未就绪", domain.ErrNotConfigured)
	}
	list, err := s.chats.Messages(ctx, chatID)
	if err != nil {
		return nil, err
	}
	out := make([]dto.AIMessageView, 0, len(list))
	for _, m := range list {
		out = append(out, dto.NewAIMessageView(m))
	}
	return out, nil
}

// DeleteChat 删除会话及其消息。
func (s *AIService) DeleteChat(ctx context.Context, chatID int64) error {
	if chatID == 0 {
		return fmt.Errorf("%w: 缺少会话 ID", domain.ErrInvalidArgument)
	}
	if s.chats == nil {
		return fmt.Errorf("%w: 会话存储未就绪", domain.ErrNotConfigured)
	}
	// 正在生成时先停掉，否则回答会在会话删除后写回来。
	s.stopAnswer(chatID)
	return s.chats.DeleteChat(ctx, chatID)
}

// ── 提问 ────────────────────────────────────────────────────

// aiAnswerJob 是一次正在进行的回答。
type aiAnswerJob struct {
	chatID int64
	bookID int64
	cancel context.CancelFunc
	doneCh chan struct{}
}

// Ask 发起一次提问，立即返回；回答通过事件流式推送。
//
// 为什么不返回答案：SSE 是边生成边到达的，同步等待会让绑定方法挂上一分钟，
// 前端既看不到过程也无法中途停止，与书源调试逐行打点的问题完全一致。
func (s *AIService) Ask(ctx context.Context, chatID int64, question string) error {
	if chatID == 0 {
		return fmt.Errorf("%w: 缺少会话 ID", domain.ErrInvalidArgument)
	}
	question = strings.TrimSpace(question)
	if question == "" {
		return fmt.Errorf("%w: 问题不能为空", domain.ErrInvalidArgument)
	}
	if s.chats == nil || s.content == nil {
		return fmt.Errorf("%w: AI 问答未就绪", domain.ErrNotConfigured)
	}

	cfg, err := s.config(ctx)
	if err != nil {
		return err
	}
	if !cfg.Configured() {
		return errAIUnset
	}

	chat, err := s.chats.GetChat(ctx, chatID)
	if err != nil {
		return err
	}

	s.answerMu.Lock()
	if _, running := s.answers[chatID]; running {
		s.answerMu.Unlock()
		return fmt.Errorf("%w: 这个会话还在回答上一条问题", domain.ErrAlreadyExists)
	}
	jobCtx, cancel := context.WithCancel(context.Background())
	job := &aiAnswerJob{chatID: chatID, bookID: chat.BookID, cancel: cancel, doneCh: make(chan struct{})}
	s.answers[chatID] = job
	s.answerMu.Unlock()

	// 历史与资料都在后台准备：它们要查库甚至调 embedding，不该阻塞绑定方法返回。
	go s.runAnswer(jobCtx, job, cfg, chat, question)
	return nil
}

// StopAnswer 停止某会话正在生成的回答。
func (s *AIService) StopAnswer(ctx context.Context, chatID int64) error {
	if chatID == 0 {
		return fmt.Errorf("%w: 缺少会话 ID", domain.ErrInvalidArgument)
	}
	s.stopAnswer(chatID)
	return nil
}

// stopAnswer 取消并等待回答真正退出。
func (s *AIService) stopAnswer(chatID int64) {
	s.answerMu.Lock()
	job, ok := s.answers[chatID]
	s.answerMu.Unlock()
	if !ok {
		return
	}
	job.cancel()
	select {
	case <-job.doneCh:
	case <-time.After(5 * time.Second):
	}
}

// runAnswer 装配上下文、流式生成、落库并推送结束事件。
func (s *AIService) runAnswer(ctx context.Context, job *aiAnswerJob,
	cfg *domain.AIConfig, chat *domain.AIChat, question string) {

	defer s.removeAnswer(job.chatID)
	defer close(job.doneCh)

	fail := func(err error) {
		state := dto.AIAnswerStateFailed
		msg := err.Error()
		if ctx.Err() != nil {
			state = dto.AIAnswerStateCanceled
			msg = ""
		}
		s.emitAnswerDone(job, state, "", nil, msg, "")
	}

	book, _, err := s.content.BookAndChapters(ctx, chat.BookID)
	if err != nil {
		fail(err)
		return
	}

	// ① 召回 + ② 装配
	recall := s.recall(ctx, cfg, chat.BookID, question, aiDefaultTopK)
	built := s.buildContext(ctx, cfg, book, recall)

	// ③ 历史对话：放在资料之后、问题之前。
	history, err := s.historyMessages(ctx, chat.ID)
	if err != nil {
		fail(err)
		return
	}
	msgs := make([]port.ChatMessage, 0, len(built.Messages)+len(history)+1)
	msgs = append(msgs, built.Messages...)
	msgs = append(msgs, history...)
	msgs = append(msgs, port.ChatMessage{Role: domain.AIRoleUser, Content: question})

	// 用户消息先落库：即使模型调用失败，提问本身也不该丢。
	userMsg := &domain.AIMessage{ChatID: chat.ID, Role: domain.AIRoleUser, Content: question}
	if err := s.chats.AddMessage(ctx, userMsg); err != nil {
		fail(err)
		return
	}

	// ④ 流式生成
	var (
		mu      sync.Mutex
		sb      strings.Builder
		seq     int
		last    time.Time
		pending strings.Builder
	)

	flush := func(force bool) {
		mu.Lock()
		defer mu.Unlock()
		if pending.Len() == 0 {
			return
		}
		if !force && time.Since(last) < aiAnswerThrottle && pending.Len() < aiAnswerFlushRunes*3 {
			return
		}
		seq++
		delta := pending.String()
		pending.Reset()
		last = time.Now()
		s.emitAnswerChunk(job, delta, seq)
	}

	resp, err := s.llm.ChatStream(ctx, *cfg, port.ChatRequest{
		Messages: msgs,
		// 温度取配置值；未设置时交给服务端默认，避免强行贪心解码让回答变生硬。
		Temperature: tempPtr(cfg.Temperature),
	}, func(delta string) error {
		mu.Lock()
		sb.WriteString(delta)
		pending.WriteString(delta)
		mu.Unlock()
		flush(false)
		return nil
	})

	// 无论成功与否，先把缓冲里的尾巴发出去，否则前端会少最后一段。
	flush(true)

	if err != nil {
		if ctx.Err() != nil {
			// 用户点了停止：保留已生成的部分，并如实告知是「已停止」。
			s.finishAnswer(job, chat, sb.String(), built.Refs, dto.AIAnswerStateCanceled, "", recall.Note)
			return
		}
		// 已经收到部分内容时也算部分成功，别把界面清空。
		if sb.Len() > 0 {
			s.finishAnswer(job, chat, sb.String(), built.Refs, dto.AIAnswerStateFailed,
				wrapAIRemoteError(err).Error(), recall.Note)
			return
		}
		fail(wrapAIRemoteError(err))
		return
	}

	content := strings.TrimSpace(resp.Content)
	if content == "" {
		content = strings.TrimSpace(sb.String())
	}
	if content == "" {
		fail(fmt.Errorf("%w: 模型返回了空回答", domain.ErrRemoteFailed))
		return
	}
	s.finishAnswer(job, chat, content, built.Refs, dto.AIAnswerStateDone, "", recall.Note)
}

// finishAnswer 落库助手消息并推送结束事件。
func (s *AIService) finishAnswer(job *aiAnswerJob, chat *domain.AIChat,
	content string, refs []domain.AIRef, state, errMsg, note string) {

	if content != "" {
		msg := &domain.AIMessage{
			ChatID:  chat.ID,
			Role:    domain.AIRoleAssistant,
			Content: content,
			Refs:    refs,
		}
		// 落库失败不改变用户看到的结果，但要把原因带回去。
		if err := s.chats.AddMessage(context.Background(), msg); err != nil && errMsg == "" {
			errMsg = "回答已生成但保存失败：" + err.Error()
		}
		_ = s.chats.TouchChat(context.Background(), chat.ID)
	}
	s.emitAnswerDone(job, state, content, refs, errMsg, note)
}

// historyMessages 取最近若干条历史，转成模型消息。
func (s *AIService) historyMessages(ctx context.Context, chatID int64) ([]port.ChatMessage, error) {
	list, err := s.chats.Messages(ctx, chatID)
	if err != nil {
		return nil, err
	}
	if len(list) > aiHistoryMessages {
		list = list[len(list)-aiHistoryMessages:]
	}
	out := make([]port.ChatMessage, 0, len(list))
	for _, m := range list {
		if strings.TrimSpace(m.Content) == "" {
			continue
		}
		out = append(out, port.ChatMessage{Role: m.Role, Content: m.Content})
	}
	return out, nil
}

// ── 事件 ────────────────────────────────────────────────────

func (s *AIService) removeAnswer(chatID int64) {
	s.answerMu.Lock()
	delete(s.answers, chatID)
	s.answerMu.Unlock()
}

func (s *AIService) emitAnswerChunk(job *aiAnswerJob, delta string, seq int) {
	if s.bus == nil || delta == "" {
		return
	}
	_ = s.bus.Emit(context.Background(), port.EventAIAnswerChunk, dto.AIAnswerChunk{
		ChatID: job.chatID, BookID: job.bookID, Delta: delta, Seq: seq,
	})
}

func (s *AIService) emitAnswerDone(job *aiAnswerJob, state, content string,
	refs []domain.AIRef, errMsg, note string) {
	if s.bus == nil {
		return
	}
	_ = s.bus.Emit(context.Background(), port.EventAIAnswerDone, dto.AIAnswerDone{
		ChatID: job.chatID, BookID: job.bookID, State: state,
		Content: content, Refs: dto.NewAIRefViews(refs), Error: errMsg, Note: note,
	})
}

// tempPtr 把 0 值当成「未设置」。
//
// 显式区分「不传」与「传 0」很必要：部分服务端把 temperature=0 当作
// 必须显式开启的贪心解码，无脑传 0 会让回答僵化。
func tempPtr(t float64) *float64 {
	if t <= 0 {
		return nil
	}
	v := t
	return &v
}
