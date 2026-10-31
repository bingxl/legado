package app

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 会话仓储替身 ────────────────────────────────────────────────

type fakeChatRepo struct {
	mu       sync.Mutex
	nextChat int64
	nextMsg  int64
	chats    map[int64]*domain.AIChat
	msgs     map[int64][]*domain.AIMessage
}

func newFakeChatRepo() *fakeChatRepo {
	return &fakeChatRepo{
		chats: make(map[int64]*domain.AIChat),
		msgs:  make(map[int64][]*domain.AIMessage),
	}
}

func (r *fakeChatRepo) CreateChat(_ context.Context, c *domain.AIChat) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextChat++
	c.ID = r.nextChat
	now := time.Now()
	c.CreatedAt, c.UpdatedAt = now, now
	cp := *c
	r.chats[c.ID] = &cp
	return nil
}

func (r *fakeChatRepo) GetChat(_ context.Context, id int64) (*domain.AIChat, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	c, ok := r.chats[id]
	if !ok {
		return nil, domain.ErrNotFound
	}
	cp := *c
	return &cp, nil
}

func (r *fakeChatRepo) ListChats(_ context.Context, bookID int64) ([]*domain.AIChat, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*domain.AIChat, 0, len(r.chats))
	for _, c := range r.chats {
		if c.BookID != bookID {
			continue
		}
		cp := *c
		out = append(out, &cp)
	}
	// 与真实仓储一致：最近更新的排前面。
	sort.Slice(out, func(i, j int) bool { return out[i].UpdatedAt.After(out[j].UpdatedAt) })
	return out, nil
}

func (r *fakeChatRepo) TouchChat(_ context.Context, id int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if c, ok := r.chats[id]; ok {
		c.UpdatedAt = time.Now()
	}
	return nil
}

func (r *fakeChatRepo) DeleteChat(_ context.Context, id int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.chats, id)
	delete(r.msgs, id)
	return nil
}

func (r *fakeChatRepo) AddMessage(_ context.Context, m *domain.AIMessage) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextMsg++
	m.ID = r.nextMsg
	if m.CreatedAt.IsZero() {
		m.CreatedAt = time.Now()
	}
	cp := *m
	r.msgs[m.ChatID] = append(r.msgs[m.ChatID], &cp)
	return nil
}

func (r *fakeChatRepo) Messages(_ context.Context, chatID int64) ([]*domain.AIMessage, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*domain.AIMessage, 0, len(r.msgs[chatID]))
	for _, m := range r.msgs[chatID] {
		cp := *m
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

// ── 辅助 ────────────────────────────────────────────────────────

// newChatEnv 组装一个已配好 AI 的环境，并建好一个会话。
func newChatEnv(t *testing.T) (*aiEnv, dto.AIChatView) {
	t.Helper()
	env := newAIEnv(t, 3, simpleAIConfig())
	chat, err := env.svc.CreateChat(context.Background(), env.book.ID, "测试对话")
	if err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}
	return env, chat
}

// waitAnswerDone 等某会话的结束事件。
func waitAnswerDone(t *testing.T, env *aiEnv, chatID int64) dto.AIAnswerDone {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, p := range env.bus.byName(port.EventAIAnswerDone) {
			done, ok := p.(dto.AIAnswerDone)
			if ok && done.ChatID == chatID {
				return done
			}
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("会话 %d 的回答没有在超时内结束", chatID)
	return dto.AIAnswerDone{}
}

// chunksOf 取出某会话收到的所有分片。
func chunksOf(env *aiEnv, chatID int64) []dto.AIAnswerChunk {
	var out []dto.AIAnswerChunk
	for _, p := range env.bus.byName(port.EventAIAnswerChunk) {
		if c, ok := p.(dto.AIAnswerChunk); ok && c.ChatID == chatID {
			out = append(out, c)
		}
	}
	return out
}

// ── 会话管理 ────────────────────────────────────────────────────

func TestCreateChatRequiresBookID(t *testing.T) {
	env := newAIEnv(t, 1, simpleAIConfig())
	if _, err := env.svc.CreateChat(context.Background(), 0, "x"); err == nil {
		t.Fatal("缺书籍 ID 时应报错")
	}
}

// 新建会话要带上当前模型，方便历史列表展示「这是哪个模型答的」。
func TestCreateChatRecordsModel(t *testing.T) {
	env, chat := newChatEnv(t)
	if chat.Model != "test-model" {
		t.Fatalf("应记录当前模型，实际 %q", chat.Model)
	}
	if chat.Title == "" || chat.BookID != env.book.ID {
		t.Fatalf("会话信息不完整: %+v", chat)
	}
}

func TestListChatsSortedByUpdate(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	first, _ := env.svc.CreateChat(context.Background(), env.book.ID, "第一个")
	time.Sleep(2 * time.Millisecond)
	second, _ := env.svc.CreateChat(context.Background(), env.book.ID, "第二个")

	list, err := env.svc.ListChats(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("列出会话失败: %v", err)
	}
	if len(list) != 2 || list[0].ID != second.ID || list[1].ID != first.ID {
		t.Fatalf("应按更新时间倒序: %+v", list)
	}
}

func TestDeleteChatRemovesMessages(t *testing.T) {
	env, chat := newChatEnv(t)
	_ = env.chats.AddMessage(context.Background(), &domain.AIMessage{
		ChatID: chat.ID, Role: domain.AIRoleUser, Content: "你好",
	})

	if err := env.svc.DeleteChat(context.Background(), chat.ID); err != nil {
		t.Fatalf("删除会话失败: %v", err)
	}
	if msgs, _ := env.chats.Messages(context.Background(), chat.ID); len(msgs) != 0 {
		t.Fatalf("消息应一并删除，实际剩 %d 条", len(msgs))
	}
	if _, err := env.chats.GetChat(context.Background(), chat.ID); err == nil {
		t.Fatal("会话应已删除")
	}
}

func TestDeleteChatRequiresID(t *testing.T) {
	env := newAIEnv(t, 1, simpleAIConfig())
	if err := env.svc.DeleteChat(context.Background(), 0); err == nil {
		t.Fatal("缺会话 ID 时应报错")
	}
	if _, err := env.svc.GetMessages(context.Background(), 0); err == nil {
		t.Fatal("缺会话 ID 时应报错")
	}
}

// ── 提问 ────────────────────────────────────────────────────────

func TestAskRequiresConfig(t *testing.T) {
	env := newAIEnv(t, 1, nil)
	chat, err := env.svc.CreateChat(context.Background(), env.book.ID, "对话")
	if err != nil {
		t.Fatalf("创建会话失败: %v", err)
	}
	err = env.svc.Ask(context.Background(), chat.ID, "这本书讲了什么")
	if err == nil || !errors.Is(err, domain.ErrNotConfigured) {
		t.Fatalf("未配置时应报错，实际 %v", err)
	}
}

func TestAskRejectsEmptyQuestion(t *testing.T) {
	env, chat := newChatEnv(t)
	if err := env.svc.Ask(context.Background(), chat.ID, "   "); err == nil {
		t.Fatal("空问题应报错")
	}
}

// 正常路径：分片按序推送、结束事件带全文与引用、两边都落库。
func TestAskStreamsAndPersists(t *testing.T) {
	env, chat := newChatEnv(t)
	seedChunks(t, env.chunks, env.book.ID, []string{"刀具磨损主要取决于切削温度"}, nil)
	env.llm.deltas = []string{"刀具", "磨损", "取决于", "温度"}

	if err := env.svc.Ask(context.Background(), chat.ID, "刀具磨损取决于什么"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)

	if done.State != dto.AIAnswerStateDone {
		t.Fatalf("状态应为 done，实际 %q（%s）", done.State, done.Error)
	}
	if done.Content != "刀具磨损取决于温度" {
		t.Fatalf("回答内容不符: %q", done.Content)
	}
	if len(done.Refs) == 0 {
		t.Fatal("有索引时应带引用")
	}

	chunks := chunksOf(env, chat.ID)
	if len(chunks) == 0 {
		t.Fatal("应有流式分片")
	}
	var joined string
	prev := 0
	for _, c := range chunks {
		if c.Seq != prev+1 {
			t.Fatalf("分片序号应连续递增: %d → %d", prev, c.Seq)
		}
		prev = c.Seq
		joined += c.Delta
	}
	if joined != done.Content {
		t.Fatalf("分片拼起来应与最终全文一致: %q vs %q", joined, done.Content)
	}

	msgs, err := env.chats.Messages(context.Background(), chat.ID)
	if err != nil {
		t.Fatalf("读取消息失败: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("应落库 2 条消息（问 + 答），实际 %d", len(msgs))
	}
	if msgs[0].Role != domain.AIRoleUser || msgs[0].Content != "刀具磨损取决于什么" {
		t.Fatalf("用户消息不对: %+v", msgs[0])
	}
	if msgs[1].Role != domain.AIRoleAssistant || msgs[1].Content != done.Content {
		t.Fatalf("回答消息不对: %+v", msgs[1])
	}
	if len(msgs[1].Refs) == 0 {
		t.Fatal("回答应带上引用，供前端跳转")
	}
}

// 没有索引也要能问：明确告知资料缺失，而不是拒绝服务。
func TestAskWithoutIndexStillAnswers(t *testing.T) {
	env, chat := newChatEnv(t)
	env.llm.deltas = []string{"书里没有相关记录"}

	if err := env.svc.Ask(context.Background(), chat.ID, "主角叫什么"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)
	if done.State != dto.AIAnswerStateDone {
		t.Fatalf("无索引也应正常回答，实际 %q（%s）", done.State, done.Error)
	}
	if done.Note == "" || !strings.Contains(done.Note, "索引") {
		t.Fatalf("应说明索引缺失，实际 %q", done.Note)
	}
	if len(done.Refs) != 0 {
		t.Fatalf("无索引不该有引用: %+v", done.Refs)
	}
}

// 同一会话不允许并发回答，否则两条回答会交错写进同一段历史。
func TestAskRejectsConcurrentAsk(t *testing.T) {
	env, chat := newChatEnv(t)
	gate := make(chan struct{})
	env.llm.streamGate = gate
	// 至少两片：第一片放行后第二片会被 gate 拦住，任务才真的「进行中」。
	env.llm.deltas = []string{"第一段", "第二段"}

	if err := env.svc.Ask(context.Background(), chat.ID, "第一个问题"); err != nil {
		t.Fatalf("首次提问失败: %v", err)
	}
	// 等它真的开始流式输出，确保任务已登记。
	waitFor(t, "回答开始", func() bool { return len(chunksOf(env, chat.ID)) > 0 })

	err := env.svc.Ask(context.Background(), chat.ID, "第二个问题")
	if err == nil || !errors.Is(err, domain.ErrAlreadyExists) {
		t.Fatalf("并发提问应被拒绝，实际 %v", err)
	}

	close(gate)
	waitAnswerDone(t, env, chat.ID)
}

// 停止生成后，已产生的部分要留下（用户看到的不能被抹掉），状态标为已取消。
func TestStopAnswerKeepsPartial(t *testing.T) {
	env, chat := newChatEnv(t)
	gate := make(chan struct{})
	env.llm.streamGate = gate
	env.llm.deltas = []string{"第一段", "第二段", "第三段"}

	if err := env.svc.Ask(context.Background(), chat.ID, "讲讲情节"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	waitFor(t, "回答开始", func() bool { return len(chunksOf(env, chat.ID)) > 0 })

	if err := env.svc.StopAnswer(context.Background(), chat.ID); err != nil {
		t.Fatalf("停止失败: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)

	if done.State != dto.AIAnswerStateCanceled {
		t.Fatalf("状态应为 canceled，实际 %q", done.State)
	}
	if done.Content == "" {
		t.Fatal("已生成的部分应保留")
	}
	msgs, _ := env.chats.Messages(context.Background(), chat.ID)
	if len(msgs) != 2 {
		t.Fatalf("部分回答也应落库，实际 %d 条消息", len(msgs))
	}
	if msgs[1].Content != done.Content {
		t.Fatalf("落库内容与推送内容不一致: %q vs %q", msgs[1].Content, done.Content)
	}
}

// 一条都没吐出来就失败时，只留用户消息，别写一条空的回答。
func TestAskModelFailureLeavesNoAssistantMessage(t *testing.T) {
	env, chat := newChatEnv(t)
	env.llm.streamErr = &port.AIError{Kind: port.AIErrAuth, Status: 401, Message: "Invalid API key"}

	if err := env.svc.Ask(context.Background(), chat.ID, "问题"); err != nil {
		t.Fatalf("提问应立即可返回: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)

	if done.State != dto.AIAnswerStateFailed {
		t.Fatalf("状态应为 failed，实际 %q", done.State)
	}
	if !strings.Contains(done.Error, "Invalid API key") {
		t.Fatalf("应带上可读错误，实际 %q", done.Error)
	}
	msgs, _ := env.chats.Messages(context.Background(), chat.ID)
	if len(msgs) != 1 || msgs[0].Role != domain.AIRoleUser {
		t.Fatalf("只应留下用户消息，实际 %+v", msgs)
	}
}

// 已经吐出部分内容后断开，算部分成功：内容要留下，同时如实告知失败。
func TestAskPartialFailureKeepsContent(t *testing.T) {
	env, chat := newChatEnv(t)
	env.llm.deltas = []string{"前半段"}
	env.llm.streamErr = errors.New("连接被重置")

	if err := env.svc.Ask(context.Background(), chat.ID, "问题"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)

	if done.State != dto.AIAnswerStateFailed {
		t.Fatalf("状态应为 failed，实际 %q", done.State)
	}
	if done.Content != "前半段" {
		t.Fatalf("部分内容应保留，实际 %q", done.Content)
	}
	msgs, _ := env.chats.Messages(context.Background(), chat.ID)
	if len(msgs) != 2 {
		t.Fatalf("部分回答应落库，实际 %d 条", len(msgs))
	}
}

// 历史要截断，否则几十轮之后检索到的原文会被挤掉。
func TestAskTrimsHistory(t *testing.T) {
	env, chat := newChatEnv(t)
	for i := 0; i < 20; i++ {
		role := domain.AIRoleUser
		if i%2 == 1 {
			role = domain.AIRoleAssistant
		}
		_ = env.chats.AddMessage(context.Background(), &domain.AIMessage{
			ChatID: chat.ID, Role: role, Content: fmt.Sprintf("历史第%d条", i+1),
		})
	}
	env.llm.deltas = []string{"好"}

	if err := env.svc.Ask(context.Background(), chat.ID, "新问题"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	waitAnswerDone(t, env, chat.ID)

	req := env.llm.streamReq
	history := 0
	for _, m := range req.Messages {
		if strings.Contains(m.Content, "历史第") {
			history++
		}
	}
	if history > aiHistoryMessages {
		t.Fatalf("历史最多带 %d 条，实际带 %d 条", aiHistoryMessages, history)
	}
	if history == 0 {
		t.Fatal("应带上一部分历史，否则多轮对话不成立")
	}
	if last := req.Messages[len(req.Messages)-1]; last.Content != "新问题" {
		t.Fatalf("最后一条应是本次问题: %+v", last)
	}
}

// 未配置向量模型时仍要能答，并把降级说明带回去。
func TestAskNotesKeywordFallback(t *testing.T) {
	env, chat := newChatEnv(t)
	seedChunks(t, env.chunks, env.book.ID, []string{"刀具前角影响切削力"}, nil)
	env.llm.deltas = []string{"前角越大切削力越小"}

	if err := env.svc.Ask(context.Background(), chat.ID, "前角影响什么"); err != nil {
		t.Fatalf("提问失败: %v", err)
	}
	done := waitAnswerDone(t, env, chat.ID)
	if !strings.Contains(done.Note, "未配置向量模型") {
		t.Fatalf("应说明降级为关键词匹配，实际 %q", done.Note)
	}
	if len(done.Refs) == 0 {
		t.Fatal("关键词召回也应有引用")
	}
}

func TestGetMessagesReturnsRefs(t *testing.T) {
	env, chat := newChatEnv(t)
	refs := []domain.AIRef{{ChunkID: 7, ChapterIdx: 2, Title: "第3章", Score: 0.9, Excerpt: "摘录"}}
	_ = env.chats.AddMessage(context.Background(), &domain.AIMessage{
		ChatID: chat.ID, Role: domain.AIRoleAssistant, Content: "回答", Refs: refs,
	})

	msgs, err := env.svc.GetMessages(context.Background(), chat.ID)
	if err != nil {
		t.Fatalf("读取消息失败: %v", err)
	}
	if len(msgs) != 1 || len(msgs[0].Refs) != 1 {
		t.Fatalf("引用没有正确转换: %+v", msgs)
	}
	if msgs[0].Refs[0].ChapterIdx != 2 || msgs[0].Refs[0].Excerpt != "摘录" {
		t.Fatalf("引用内容不符: %+v", msgs[0].Refs[0])
	}
	if msgs[0].CreatedAt == "" {
		t.Fatal("应带创建时间")
	}
}
