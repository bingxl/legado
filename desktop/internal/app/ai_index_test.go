package app

import (
	"context"
	"encoding/json"
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

// ── 测试替身 ────────────────────────────────────────────────────

// fakeSettingStore 是内存版配置存储。
type fakeSettingStore struct {
	mu   sync.Mutex
	data map[string]string
}

func newFakeSettingStore() *fakeSettingStore {
	return &fakeSettingStore{data: make(map[string]string)}
}

func (f *fakeSettingStore) Get(_ context.Context, key string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	v, ok := f.data[key]
	if !ok {
		return "", domain.ErrNotFound
	}
	return v, nil
}

func (f *fakeSettingStore) Set(_ context.Context, key, value string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.data[key] = value
	return nil
}

func (f *fakeSettingStore) Delete(_ context.Context, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.data, key)
	return nil
}

// fakeLLM 记录调用次数与输入，供「不重复花钱」类的断言使用。
type fakeLLM struct {
	mu sync.Mutex

	chatCalls  int
	embedCalls int
	chatInput  []string // 每次 Chat 的 user 输入

	chatErr  error
	embedErr error
	// gate 非 nil 时 Chat 会阻塞到它关闭（或 ctx 结束），用于构造「任务进行中」。
	gate chan struct{}
	// embedDim 为 0 时按 8 维返回。
	embedDim int
	// embedFunc 定制返回向量（按输入顺序）；为 nil 时按 embedDim 造固定向量。
	embedFunc func(inputs []string) [][]float32
	// reply 定制摘要内容；为 nil 时返回固定短句。
	reply func(input string) string

	// 流式相关：deltas 依次回调，streamGate 非 nil 时逐片等待，
	// streamErr 在吐出 deltas 之后返回。
	deltas     []string
	streamGate chan struct{}
	streamErr  error
	streamReq  port.ChatRequest
}

func (f *fakeLLM) Chat(ctx context.Context, _ domain.AIConfig, req port.ChatRequest) (port.ChatResponse, error) {
	var input string
	for _, m := range req.Messages {
		if m.Role == domain.AIRoleUser {
			input = m.Content
		}
	}

	f.mu.Lock()
	f.chatCalls++
	gate, chatErr := f.gate, f.chatErr
	f.mu.Unlock()

	if gate != nil {
		select {
		case <-gate:
		case <-ctx.Done():
			return port.ChatResponse{}, ctx.Err()
		}
	}
	if chatErr != nil {
		return port.ChatResponse{}, chatErr
	}

	f.mu.Lock()
	f.chatInput = append(f.chatInput, input)
	reply := f.reply
	f.mu.Unlock()

	out := "这段内容讲了主角的一段经历，并留下了一个悬念。"
	if reply != nil {
		out = reply(input)
	}
	return port.ChatResponse{Content: out}, nil
}

func (f *fakeLLM) ChatStream(ctx context.Context, _ domain.AIConfig, req port.ChatRequest,
	onDelta func(string) error) (port.ChatResponse, error) {

	f.mu.Lock()
	f.chatCalls++
	f.streamReq = req
	deltas := append([]string(nil), f.deltas...)
	gate := f.streamGate
	streamErr := f.streamErr
	f.mu.Unlock()

	var sb strings.Builder
	for i, d := range deltas {
		// 第一片先放行：测试要能等到「确实开始流式输出」这个信号，
		// 若第一片就被拦住，外面无法区分「正在生成」与「还没开始」。
		if gate != nil && i > 0 {
			select {
			case <-gate:
			case <-ctx.Done():
				return port.ChatResponse{Content: sb.String()}, ctx.Err()
			}
		}
		if err := ctx.Err(); err != nil {
			return port.ChatResponse{Content: sb.String()}, err
		}
		if err := onDelta(d); err != nil {
			return port.ChatResponse{Content: sb.String()}, err
		}
		sb.WriteString(d)
	}
	if streamErr != nil {
		return port.ChatResponse{Content: sb.String()}, streamErr
	}
	return port.ChatResponse{Content: sb.String()}, nil
}

func (f *fakeLLM) Embed(_ context.Context, _ domain.AIConfig, _ string, inputs []string) ([][]float32, error) {
	f.mu.Lock()
	f.embedCalls++
	embedErr, dim, fn := f.embedErr, f.embedDim, f.embedFunc
	f.mu.Unlock()

	if embedErr != nil {
		return nil, embedErr
	}
	if fn != nil {
		return fn(inputs), nil
	}
	if dim <= 0 {
		dim = 8
	}
	out := make([][]float32, len(inputs))
	for i := range inputs {
		vec := make([]float32, dim)
		vec[0] = 1
		out[i] = vec
	}
	return out, nil
}

func (f *fakeLLM) setGate(g chan struct{}) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gate = g
}

func (f *fakeLLM) counts() (chat, embed int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.chatCalls, f.embedCalls
}

func (f *fakeLLM) inputs() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.chatInput...)
}

// fakeChunkRepo 是内存版切片仓储。
type fakeChunkRepo struct {
	mu     sync.Mutex
	nextID int64
	data   map[int64]map[int]*domain.AIChunk // bookID -> ordinal -> chunk
}

func newFakeChunkRepo() *fakeChunkRepo {
	return &fakeChunkRepo{data: make(map[int64]map[int]*domain.AIChunk)}
}

func (r *fakeChunkRepo) PutBulk(_ context.Context, chunks []*domain.AIChunk) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range chunks {
		if r.data[c.BookID] == nil {
			r.data[c.BookID] = make(map[int]*domain.AIChunk)
		}
		cp := *c
		if old, ok := r.data[c.BookID][c.Ordinal]; ok {
			cp.ID = old.ID
			// 与真实仓储语义一致：正文哈希未变时保留旧向量。
			// 这条规则是「重新索引不重复花钱」的基础，替身必须照做，
			// 否则测出来的复用结论不成立。
			if old.SrcHash == c.SrcHash {
				cp.Embedding, cp.EmbModel, cp.EmbDim = old.Embedding, old.EmbModel, old.EmbDim
			}
		} else {
			r.nextID++
			cp.ID = r.nextID
		}
		r.data[c.BookID][c.Ordinal] = &cp
	}
	return nil
}

func (r *fakeChunkRepo) UpdateEmbedding(_ context.Context, id int64, vec []float32, model string, dim int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, list := range r.data {
		for _, c := range list {
			if c.ID == id {
				c.Embedding, c.EmbModel, c.EmbDim = vec, model, dim
				return nil
			}
		}
	}
	return domain.ErrNotFound
}

func (r *fakeChunkRepo) List(_ context.Context, bookID int64) ([]*domain.AIChunk, error) {
	return r.ListRange(context.Background(), bookID, -1<<31, 1<<31)
}

func (r *fakeChunkRepo) ListRange(_ context.Context, bookID int64, from, to int) ([]*domain.AIChunk, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]*domain.AIChunk, 0, len(r.data[bookID]))
	for _, c := range r.data[bookID] {
		if c.Ordinal < from || c.Ordinal > to {
			continue
		}
		cp := *c
		out = append(out, &cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ordinal < out[j].Ordinal })
	return out, nil
}

func (r *fakeChunkRepo) Get(_ context.Context, id int64) (*domain.AIChunk, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, list := range r.data {
		for _, c := range list {
			if c.ID == id {
				cp := *c
				return &cp, nil
			}
		}
	}
	return nil, domain.ErrNotFound
}

func (r *fakeChunkRepo) Count(_ context.Context, bookID int64) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.data[bookID]), nil
}

func (r *fakeChunkRepo) CountWithVector(_ context.Context, bookID int64) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, c := range r.data[bookID] {
		if c.HasVector() {
			n++
		}
	}
	return n, nil
}

func (r *fakeChunkRepo) DeleteBeyond(_ context.Context, bookID int64, maxOrdinal int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for ord := range r.data[bookID] {
		if ord > maxOrdinal {
			delete(r.data[bookID], ord)
		}
	}
	return nil
}

func (r *fakeChunkRepo) DeleteByBook(_ context.Context, bookID int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.data, bookID)
	return nil
}

func (r *fakeChunkRepo) DeleteByChapters(_ context.Context, bookID int64, from, to int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for ord, c := range r.data[bookID] {
		if c.ChapterIdx >= from && c.ChapterIdx <= to {
			delete(r.data[bookID], ord)
		}
	}
	return nil
}

// fakeSummaryRepo 是内存版分层摘要仓储。
type fakeSummaryRepo struct {
	mu   sync.Mutex
	data map[summaryKey]*domain.AISummary
}

type summaryKey struct {
	bookID  int64
	level   int
	ordinal int
}

func newFakeSummaryRepo() *fakeSummaryRepo {
	return &fakeSummaryRepo{data: make(map[summaryKey]*domain.AISummary)}
}

func (r *fakeSummaryRepo) Put(_ context.Context, s *domain.AISummary) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	cp := *s
	if cp.UpdatedAt.IsZero() {
		cp.UpdatedAt = time.Now()
	}
	r.data[summaryKey{s.BookID, s.Level, s.Ordinal}] = &cp
	return nil
}

func (r *fakeSummaryRepo) Level(_ context.Context, bookID int64, level int) ([]*domain.AISummary, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []*domain.AISummary
	for k, s := range r.data {
		if k.bookID == bookID && k.level == level {
			cp := *s
			out = append(out, &cp)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Ordinal < out[j].Ordinal })
	return out, nil
}

func (r *fakeSummaryRepo) Top(_ context.Context, bookID int64) (*domain.AISummary, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	var best *domain.AISummary
	for k, s := range r.data {
		if k.bookID != bookID {
			continue
		}
		if best == nil || k.level > best.Level ||
			(k.level == best.Level && k.ordinal < best.Ordinal) {
			cp := *s
			best = &cp
		}
	}
	if best == nil {
		return nil, domain.ErrNotFound
	}
	return best, nil
}

func (r *fakeSummaryRepo) MaxLevel(_ context.Context, bookID int64) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	max := 0
	for k := range r.data {
		if k.bookID == bookID && k.level > max {
			max = k.level
		}
	}
	return max, nil
}

func (r *fakeSummaryRepo) DeleteByBook(_ context.Context, bookID int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for k := range r.data {
		if k.bookID == bookID {
			delete(r.data, k)
		}
	}
	return nil
}

func (r *fakeSummaryRepo) DeleteFromLevel(_ context.Context, bookID int64, level int) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	for k := range r.data {
		if k.bookID == bookID && k.level >= level {
			delete(r.data, k)
		}
	}
	return nil
}

// fakeStateRepo 是内存版索引状态仓储。
type fakeStateRepo struct {
	mu   sync.Mutex
	data map[int64]*domain.AIIndexState
}

func newFakeStateRepo() *fakeStateRepo {
	return &fakeStateRepo{data: make(map[int64]*domain.AIIndexState)}
}

func (r *fakeStateRepo) Get(_ context.Context, bookID int64) (*domain.AIIndexState, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	st, ok := r.data[bookID]
	if !ok {
		return nil, domain.ErrNotFound
	}
	cp := *st
	return &cp, nil
}

func (r *fakeStateRepo) Put(_ context.Context, st *domain.AIIndexState) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	cp := *st
	cp.UpdatedAt = time.Now()
	r.data[st.BookID] = &cp
	return nil
}

func (r *fakeStateRepo) Delete(_ context.Context, bookID int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.data, bookID)
	return nil
}

// ── 测试环境 ────────────────────────────────────────────────────

// aiEnv 把 AI 服务连同它依赖的全部替身打包，便于逐项断言。
type aiEnv struct {
	svc      *AIService
	llm      *fakeLLM
	books    *fakeBooks
	chapters *fakeChapters
	cache    *fakeCacheRepo
	fetcher  *fakeFetcher
	chunks   *fakeChunkRepo
	sums     *fakeSummaryRepo
	states   *fakeStateRepo
	chats    *fakeChatRepo
	bus      *fakeEventBus
	book     *domain.Book
}

// newAIEnv 组装一套 AI 服务。
//
// cfg 为 nil 表示「一次都没配置过」。正文来源由缓存决定：
// 缓存里有就直读缓存（索引长文的场景），没有就走 fetcher 抓取。
func newAIEnv(t *testing.T, chapterCount int, cfg *domain.AIConfig) *aiEnv {
	t.Helper()

	book := &domain.Book{
		ID:            1,
		Name:          "测试小说",
		Kind:          domain.BookKindWeb,
		Format:        domain.BookFormatUnknown,
		Origin:        "https://example.com",
		TotalChapters: chapterCount,
	}
	books := newFakeBooks(book)
	chapters := newFakeChapters(book.ID, chapterCount)
	cache := newFakeCacheRepo()
	fetcher := &fakeFetcher{}
	content := NewContentProvider(books, chapters, fakeSourceRepo{}, nil, fetcher, cache)

	settings := newFakeSettingStore()
	if cfg != nil {
		raw, err := json.Marshal(cfg)
		if err != nil {
			t.Fatalf("序列化配置失败: %v", err)
		}
		if err := settings.Set(context.Background(), port.SettingAI, string(raw)); err != nil {
			t.Fatalf("写入配置失败: %v", err)
		}
	}

	llm := &fakeLLM{}
	bus := &fakeEventBus{}
	chunks := newFakeChunkRepo()
	sums := newFakeSummaryRepo()
	states := newFakeStateRepo()
	chats := newFakeChatRepo()

	svc := NewAIService(AIDeps{
		Settings:  settings,
		LLM:       llm,
		Bus:       bus,
		Content:   content,
		Cache:     cache,
		Chunks:    chunks,
		Summaries: sums,
		States:    states,
		Chats:     chats,
	})
	return &aiEnv{
		svc: svc, llm: llm, books: books, chapters: chapters, cache: cache,
		fetcher: fetcher, chunks: chunks, sums: sums, states: states, chats: chats,
		bus: bus, book: book,
	}
}

// simpleAIConfig 是最小可用的配置：有对话通道、无向量通道。
func simpleAIConfig() *domain.AIConfig {
	return &domain.AIConfig{BaseURL: "https://api.example.com/v1", Model: "test-model"}
}

// embedAIConfig 额外配置了向量通道。
func embedAIConfig() *domain.AIConfig {
	cfg := simpleAIConfig()
	cfg.EmbeddingModel = "test-embed"
	return cfg
}

// chapterURL 复现 fakeChapters 生成的章节地址，供缓存命中判定使用。
func chapterURL(bookID int64, index int) string {
	return fmt.Sprintf("https://example.com/book/%d/%d", bookID, index)
}

// seedCache 往缓存里放指定章节的正文。
func seedCache(t *testing.T, repo *fakeCacheRepo, bookID int64, indexes []int, text func(i int) string) {
	t.Helper()
	for _, i := range indexes {
		err := repo.Put(context.Background(), &domain.CachedChapter{
			BookID: bookID,
			Index:  i,
			Title:  fmt.Sprintf("第%d章", i+1),
			URL:    chapterURL(bookID, i),
			HTML:   "<p>" + text(i) + "</p>",
		})
		if err != nil {
			t.Fatalf("写入缓存失败: %v", err)
		}
	}
}

// longText 生成一段长度可控的中文正文（1 字符 ≈ 1 token）。
func longText(n int, prefix string) string {
	if n <= len([]rune(prefix)) {
		return prefix
	}
	return prefix + strings.Repeat("测", n-len([]rune(prefix)))
}

// waitFor 轮询直到条件成立，超时即失败。
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("等待超时：%s", what)
}

// waitIndex 等索引任务进入终态并返回最终状态。
func waitIndex(t *testing.T, env *aiEnv, bookID int64) dto.AIIndexStatusView {
	t.Helper()
	var last dto.AIIndexStatusView
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		st, err := env.svc.IndexStatus(context.Background(), bookID)
		if err != nil {
			t.Fatalf("读取索引状态失败: %v", err)
		}
		last = st
		if st.Status != domain.AIIndexRunning {
			return st
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatalf("索引任务没有在超时内结束，最后状态 %+v", last)
	return last
}

// ── 范围换算 ────────────────────────────────────────────────────

func TestResolveAIScope(t *testing.T) {
	book := &domain.Book{ID: 1, DurChapterIndex: 3}
	chapters := make([]*domain.BookChapter, 0, 10)
	for i := 0; i < 10; i++ {
		chapters = append(chapters, &domain.BookChapter{BookID: 1, Index: i})
	}

	cases := []struct {
		name    string
		scope   string
		from    int
		to      int
		wantF   int
		wantT   int
		wantErr bool
	}{
		{name: "空范围视为全书", scope: "", wantF: 0, wantT: 9},
		{name: "全书", scope: domain.AIScopeAll, wantF: 0, wantT: 9},
		{name: "已读", scope: domain.AIScopeRead, wantF: 0, wantT: 3},
		{name: "指定区间", scope: domain.AIScopeRange, from: 2, to: 5, wantF: 2, wantT: 5},
		{name: "单章区间", scope: domain.AIScopeRange, from: 4, to: 4, wantF: 4, wantT: 4},
		{name: "区间起点大于终点", scope: domain.AIScopeRange, from: 5, to: 2, wantErr: true},
		{name: "区间越界", scope: domain.AIScopeRange, from: 0, to: 99, wantErr: true},
		{name: "区间下界越界", scope: domain.AIScopeRange, from: -1, to: 3, wantErr: true},
		{name: "未知范围", scope: "chapter", wantErr: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f, to, err := resolveAIScope(book, chapters, c.scope, c.from, c.to)
			if c.wantErr {
				if err == nil {
					t.Fatalf("期望报错，实际得到 %d~%d", f, to)
				}
				if !errors.Is(err, domain.ErrInvalidArgument) {
					t.Fatalf("错误类型不符: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("不应报错: %v", err)
			}
			if f != c.wantF || to != c.wantT {
				t.Fatalf("范围不符，期望 %d~%d，实际 %d~%d", c.wantF, c.wantT, f, to)
			}
		})
	}
}

// 「已读」在没开始读时要退化成第一章，而不是报错——用户此时多半想看开头。
func TestResolveAIScopeReadBeforeStart(t *testing.T) {
	book := &domain.Book{ID: 1, DurChapterIndex: 0}
	chapters := []*domain.BookChapter{{Index: 0}, {Index: 1}, {Index: 2}}

	f, to, err := resolveAIScope(book, chapters, domain.AIScopeRead, 0, 0)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if f != 0 || to != 0 {
		t.Fatalf("应退化为第一章，实际 %d~%d", f, to)
	}
}

// 读完全书后进度可能停在末章之后（书源更新目录），要夹到末章。
func TestResolveAIScopeReadBeyondEnd(t *testing.T) {
	book := &domain.Book{ID: 1, DurChapterIndex: 99}
	chapters := []*domain.BookChapter{{Index: 0}, {Index: 1}, {Index: 2}}

	if _, to, err := resolveAIScope(book, chapters, domain.AIScopeRead, 0, 0); err != nil {
		t.Fatalf("不应报错: %v", err)
	} else if to != 2 {
		t.Fatalf("应夹到末章 2，实际 %d", to)
	}
}

// 没有目录时不能默默返回 0~0，那会让索引任务「成功但什么都没做」。
func TestResolveAIScopeNoChapters(t *testing.T) {
	if _, _, err := resolveAIScope(&domain.Book{ID: 1}, nil, domain.AIScopeAll, 0, 0); err == nil {
		t.Fatal("目录为空时应报错")
	}
}

// ── 打包 ────────────────────────────────────────────────────────

func TestGroupByTokenBudget(t *testing.T) {
	// 每 10 个 token 一条，预算 30：恰好 3 条一组（第 4 条会超预算）。
	tokens := func(int) int { return 10 }
	got := groupByTokenBudget(7, tokens, 30)
	if len(got) != 3 {
		t.Fatalf("应分成 3 组，实际 %d 组: %v", len(got), got)
	}
	// 每条都必须被分到某一组，一条都不能丢。
	var flat []int
	for _, g := range got {
		flat = append(flat, g...)
	}
	if len(flat) != 7 {
		t.Fatalf("分组后条数不符，期望 7，实际 %d", len(flat))
	}
	for i, v := range flat {
		if i != v {
			t.Fatalf("分组顺序被打乱: %v", flat)
		}
	}
}

// 单条超预算也必须独自成组，否则内容会丢且循环无法前进。
func TestGroupByTokenBudgetOversizedItem(t *testing.T) {
	got := groupByTokenBudget(3, func(int) int { return 9999 }, 100)
	if len(got) != 3 {
		t.Fatalf("超预算条目应各成一组，实际 %v", got)
	}
}

func TestGroupByTokenBudgetEdge(t *testing.T) {
	if got := groupByTokenBudget(0, func(int) int { return 1 }, 100); got != nil {
		t.Fatalf("空输入应返回 nil，实际 %v", got)
	}
	// budget<=0 时回落到默认预算，而不是「一条一组」。
	got := groupByTokenBudget(5, func(int) int { return 10 }, 0)
	if len(got) != 1 {
		t.Fatalf("应回落到默认预算并合并成 1 组，实际 %v", got)
	}
}

// ── 索引主流程 ──────────────────────────────────────────────────

// 没配置 AI 服务时，启动索引要给一句能看懂的话，而不是空指针或静默失败。
func TestStartIndexWithoutConfig(t *testing.T) {
	env := newAIEnv(t, 2, nil)

	_, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0)
	if err == nil {
		t.Fatal("未配置时应报错")
	}
	if !errors.Is(err, domain.ErrNotConfigured) {
		t.Fatalf("错误类型不符: %v", err)
	}
	if !strings.Contains(err.Error(), "设置") {
		t.Fatalf("错误信息应引导用户去配置: %v", err)
	}
}

// 三章短正文：切片、摘要都要落库，状态归为 done。
func TestIndexBuildsChunksAndSummary(t *testing.T) {
	env := newAIEnv(t, 3, simpleAIConfig())

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)

	if st.Status != domain.AIIndexDone {
		t.Fatalf("状态应为 done，实际 %q（错误 %q）", st.Status, st.Error)
	}
	if st.ChunkCount != 3 {
		t.Fatalf("应生成 3 个切片，实际 %d", st.ChunkCount)
	}
	if st.VectorCount != 0 {
		t.Fatalf("未配置向量通道时不应有向量，实际 %d", st.VectorCount)
	}
	if !st.HasSummary || strings.TrimSpace(st.Summary) == "" {
		t.Fatalf("应生成全书摘要，实际 %+v", st)
	}
	if st.ChapterFrom != 0 || st.ChapterTo != 2 {
		t.Fatalf("范围不符: %d~%d", st.ChapterFrom, st.ChapterTo)
	}

	if _, embed := env.llm.counts(); embed != 0 {
		t.Fatalf("未配置向量模型时不应调用向量接口，实际 %d 次", embed)
	}

	// 切片必须带上章节与偏移，否则前端无法跳回原文。
	chunks, _ := env.chunks.List(context.Background(), env.book.ID)
	for _, c := range chunks {
		if c.Title == "" || c.SrcHash == "" || c.CharEnd <= c.CharStart {
			t.Fatalf("切片信息不完整: %+v", c)
		}
	}

	// 进度事件里必须出现终态，否则前端会一直转圈。
	events := env.bus.byName(port.EventAIIndexProgress)
	if len(events) == 0 {
		t.Fatal("应推送索引进度事件")
	}
	last, ok := events[len(events)-1].(dto.AIIndexProgress)
	if !ok {
		t.Fatalf("事件类型不符: %T", events[len(events)-1])
	}
	if last.Phase != dto.AIPhaseDone {
		t.Fatalf("最后一个事件应为 done，实际 %q", last.Phase)
	}

	// 序号必须严格递增：前端靠它丢弃「终态之后迟到的早阶段事件」，
	// 否则界面会从「索引已就绪」翻回「索引进行中」。
	for i, e := range events {
		cur, ok := e.(dto.AIIndexProgress)
		if !ok {
			t.Fatalf("事件类型不符: %T", e)
		}
		if cur.Seq <= 0 {
			t.Fatalf("第 %d 个事件缺少序号: %+v", i, cur)
		}
		if i == 0 {
			continue
		}
		prev := events[i-1].(dto.AIIndexProgress)
		if cur.Seq <= prev.Seq {
			t.Fatalf("事件序号应严格递增: %d(%s) → %d(%s)",
				prev.Seq, prev.Phase, cur.Seq, cur.Phase)
		}
	}
}

// 长正文要能自动归并出多层摘要：单片撑不住全局，必须逐层合并。
func TestIndexBuildsMultiLevelSummary(t *testing.T) {
	env := newAIEnv(t, 10, simpleAIConfig())
	indexes := make([]int, 10)
	for i := range indexes {
		indexes[i] = i
	}
	// 每章 700 token，10 章共 7000，超过单次摘要的 6000 预算 → 必须分两层。
	seedCache(t, env.cache, env.book.ID, indexes, func(i int) string {
		return longText(700, fmt.Sprintf("第%d章内容", i+1))
	})

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)
	if st.Status != domain.AIIndexDone {
		t.Fatalf("状态应为 done，实际 %q（%s）", st.Status, st.Error)
	}
	// 进度计数必须自洽：归并多层后 done 不能超过 total，否则界面会出现「23/22」。
	if st.SummaryDone <= 0 || st.SummaryDone > st.SummaryTotal {
		t.Fatalf("摘要进度不自洽: %d/%d", st.SummaryDone, st.SummaryTotal)
	}

	level1, _ := env.sums.Level(context.Background(), env.book.ID, 1)
	if len(level1) < 2 {
		t.Fatalf("正文超过单次预算时应拆成多条一级摘要，实际 %d 条", len(level1))
	}
	maxLevel, _ := env.sums.MaxLevel(context.Background(), env.book.ID)
	if maxLevel < 2 {
		t.Fatalf("应归并出两层以上摘要，实际最高 %d 层", maxLevel)
	}
	top, err := env.sums.Top(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("应存在顶层摘要: %v", err)
	}
	if top.Level != maxLevel {
		t.Fatalf("Top 应返回最高层，实际 level=%d，最高 %d", top.Level, maxLevel)
	}
	// 每层只保留一条即全书摘要；多余的层级要被清理。
	if topLevel, _ := env.sums.Level(context.Background(), env.book.ID, maxLevel); len(topLevel) != 1 {
		t.Fatalf("顶层应只有 1 条摘要，实际 %d", len(topLevel))
	}
}

// 重新索引同一本书，输入没变就不该再花钱调模型。
func TestIndexReusesSummaryAndVectorOnRerun(t *testing.T) {
	env := newAIEnv(t, 3, embedAIConfig())

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("首次启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)
	if st.Status != domain.AIIndexDone {
		t.Fatalf("首次索引失败: %q（%s）", st.Status, st.Error)
	}
	chat1, embed1 := env.llm.counts()
	if chat1 == 0 || embed1 == 0 {
		t.Fatalf("首次索引应调用模型，实际 chat=%d embed=%d", chat1, embed1)
	}
	if st.VectorCount != 3 {
		t.Fatalf("应写入 3 条向量，实际 %d", st.VectorCount)
	}

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("二次启动索引失败: %v", err)
	}
	if st2 := waitIndex(t, env, env.book.ID); st2.Status != domain.AIIndexDone {
		t.Fatalf("二次索引失败: %q（%s）", st2.Status, st2.Error)
	}

	chat2, embed2 := env.llm.counts()
	if chat2 != chat1 {
		t.Fatalf("正文未变时不应重新生成摘要：首次 %d 次，二次共 %d 次", chat1, chat2)
	}
	if embed2 != embed1 {
		t.Fatalf("正文未变时不应重新向量化：首次 %d 次，二次共 %d 次", embed1, embed2)
	}
}

// 正文变了就必须重算，否则用户改完内容还以为索引是新的。
func TestIndexReembedsWhenTextChanges(t *testing.T) {
	env := newAIEnv(t, 2, embedAIConfig())

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("首次启动失败: %v", err)
	}
	waitIndex(t, env, env.book.ID)
	chat1, embed1 := env.llm.counts()

	// 换掉缓存正文，再索引一次。
	seedCache(t, env.cache, env.book.ID, []int{0, 1}, func(i int) string {
		return longText(200, fmt.Sprintf("改过的第%d章", i+1))
	})
	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("二次启动失败: %v", err)
	}
	waitIndex(t, env, env.book.ID)

	chat2, embed2 := env.llm.counts()
	if chat2 <= chat1 {
		t.Fatalf("正文变化后应重新生成摘要，实际 chat 仍为 %d", chat2)
	}
	if embed2 <= embed1 {
		t.Fatalf("正文变化后应重新向量化，实际 embed 仍为 %d", embed2)
	}
}

// 向量化失败不能把整本书索引判死：降级成关键词召回仍然可用，
// 但失败原因必须写进状态，否则用户会以为「配了 embedding 却不生效」。
func TestIndexDegradesWhenEmbeddingFails(t *testing.T) {
	env := newAIEnv(t, 2, embedAIConfig())
	env.llm.embedErr = errors.New("embedding 服务返回 404")

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)

	if st.Status != domain.AIIndexDone {
		t.Fatalf("向量失败不应中断索引，实际状态 %q", st.Status)
	}
	if st.ChunkCount == 0 {
		t.Fatal("切片仍应入库")
	}
	if !strings.Contains(st.Error, "关键词") {
		t.Fatalf("状态里应说明已降级为关键词匹配，实际 %q", st.Error)
	}
	if !st.HasSummary {
		t.Fatal("摘要仍应生成")
	}
}

// 单章抓不到是常态（源站偶发失败），不该让整本书索引失败。
func TestIndexSkipsUnfetchableChapters(t *testing.T) {
	env := newAIEnv(t, 3, simpleAIConfig())
	// 只缓存第 0、2 章，第 1 章走抓取，而抓取被置为失败。
	seedCache(t, env.cache, env.book.ID, []int{0, 2}, func(i int) string {
		return longText(60, fmt.Sprintf("第%d章", i+1))
	})
	env.fetcher.setFail(true)

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)

	if st.Status != domain.AIIndexDone {
		t.Fatalf("缺章不应中断索引，实际 %q（%s）", st.Status, st.Error)
	}
	if st.ChunkCount != 2 {
		t.Fatalf("应只索引 2 章，实际 %d 片", st.ChunkCount)
	}
	if !strings.Contains(st.Error, "跳过") {
		t.Fatalf("应提示有章节被跳过，实际 %q", st.Error)
	}
}

// 一章正文都没有时要明确报错，否则会出现「索引成功但搜不到东西」。
func TestIndexFailsWithoutText(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	env.fetcher.setFail(true)

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	st := waitIndex(t, env, env.book.ID)
	if st.Status != domain.AIIndexFailed {
		t.Fatalf("状态应为 failed，实际 %q", st.Status)
	}
	if !strings.Contains(st.Error, "缓存") {
		t.Fatalf("错误信息应建议先缓存，实际 %q", st.Error)
	}
}

// ── 取消与互斥 ──────────────────────────────────────────────────

// 同一本书只允许一个索引任务，否则两个任务会互相覆盖切片。
func TestStartIndexRejectsDuplicate(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	gate := make(chan struct{})
	env.llm.setGate(gate)

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("首次启动失败: %v", err)
	}
	// 等任务真正进入摘要阶段（此时必然已在跑）。
	waitFor(t, "任务进入摘要阶段", func() bool {
		chat, _ := env.llm.counts()
		return chat > 0
	})

	_, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0)
	if err == nil {
		t.Fatal("重复启动应报错")
	}
	if !errors.Is(err, domain.ErrAlreadyExists) {
		t.Fatalf("错误类型不符: %v", err)
	}

	close(gate)
	if err := env.svc.CancelIndex(context.Background(), env.book.ID); err != nil {
		t.Fatalf("取消失败: %v", err)
	}
}

// 取消后状态必须是 canceled，而不是 running 或 done。
func TestCancelIndexMarksCanceled(t *testing.T) {
	env := newAIEnv(t, 3, simpleAIConfig())
	gate := make(chan struct{})
	env.llm.setGate(gate)

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	waitFor(t, "任务进入摘要阶段", func() bool {
		chat, _ := env.llm.counts()
		return chat > 0
	})

	if err := env.svc.CancelIndex(context.Background(), env.book.ID); err != nil {
		t.Fatalf("取消失败: %v", err)
	}

	st, err := env.svc.IndexStatus(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("读取状态失败: %v", err)
	}
	if st.Status != domain.AIIndexCanceled {
		t.Fatalf("状态应为 canceled，实际 %q", st.Status)
	}
	// 必须是真正的取消，而不是等模型返回后才发现任务已杀——那笔钱已经花掉了。
	chat, _ := env.llm.counts()
	time.Sleep(20 * time.Millisecond)
	if after, _ := env.llm.counts(); after != chat {
		t.Fatalf("取消后不应继续调用模型，实际从 %d 增至 %d", chat, after)
	}
	if _, err := env.sums.Top(context.Background(), env.book.ID); err == nil {
		t.Fatal("取消后不应留下摘要")
	}
	// 取消事件要发出去，前端才知道停止转圈。
	events := env.bus.byName(port.EventAIIndexProgress)
	last, ok := events[len(events)-1].(dto.AIIndexProgress)
	if !ok || last.Phase != dto.AIPhaseCanceled {
		t.Fatalf("最后一个事件应为 canceled，实际 %+v", events[len(events)-1])
	}
}

// 取消后可以重新启动；任务表必须已经被清空。
func TestRestartAfterCancel(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	gate := make(chan struct{})
	env.llm.setGate(gate)

	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("首次启动失败: %v", err)
	}
	waitFor(t, "任务进入摘要阶段", func() bool {
		chat, _ := env.llm.counts()
		return chat > 0
	})
	if err := env.svc.CancelIndex(context.Background(), env.book.ID); err != nil {
		t.Fatalf("取消失败: %v", err)
	}

	env.llm.setGate(nil)
	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("取消后重启应成功: %v", err)
	}
	if st := waitIndex(t, env, env.book.ID); st.Status != domain.AIIndexDone {
		t.Fatalf("重启后应完成，实际 %q（%s）", st.Status, st.Error)
	}
}

// 取消一个不存在的任务不能报错：前端点两次「停止」很常见。
func TestCancelIndexWhenIdle(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	if err := env.svc.CancelIndex(context.Background(), env.book.ID); err != nil {
		t.Fatalf("空任务取消不应报错: %v", err)
	}
}

// ── 摘要查询与删除 ──────────────────────────────────────────────

// 从未索引过的书，状态查询要返回 idle 而不是错误。
func TestIndexStatusIdle(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	st, err := env.svc.IndexStatus(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if st.Status != domain.AIIndexIdle {
		t.Fatalf("状态应为 idle，实际 %q", st.Status)
	}
	if st.HasSummary || st.ChunkCount != 0 {
		t.Fatalf("空状态不应带数据: %+v", st)
	}
}

// 没有摘要时返回空视图，而不是 ErrNotFound——前端要能正常渲染。
func TestGetSummaryEmpty(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	view, err := env.svc.GetSummary(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("不应报错: %v", err)
	}
	if view.Content != "" || view.Level != 0 {
		t.Fatalf("应返回空视图，实际 %+v", view)
	}
}

func TestGetSummaryAfterIndex(t *testing.T) {
	env := newAIEnv(t, 2, simpleAIConfig())
	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	waitIndex(t, env, env.book.ID)

	view, err := env.svc.GetSummary(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("读取摘要失败: %v", err)
	}
	if view.Content == "" {
		t.Fatal("摘要内容不应为空")
	}
	if view.Model != "test-model" {
		t.Fatalf("应记录生成摘要的模型，实际 %q", view.Model)
	}
	if view.UpdatedAt == nil {
		t.Fatal("应带更新时间")
	}
}

// 删除索引要连切片、摘要、状态一起清，否则会留下「有摘要但搜不到原文」的脏数据。
func TestDeleteIndexClearsEverything(t *testing.T) {
	env := newAIEnv(t, 2, embedAIConfig())
	if _, err := env.svc.StartIndex(context.Background(), env.book.ID, domain.AIScopeAll, 0, 0); err != nil {
		t.Fatalf("启动索引失败: %v", err)
	}
	waitIndex(t, env, env.book.ID)

	if err := env.svc.DeleteIndex(context.Background(), env.book.ID); err != nil {
		t.Fatalf("删除索引失败: %v", err)
	}

	if n, _ := env.chunks.Count(context.Background(), env.book.ID); n != 0 {
		t.Fatalf("切片应被清空，实际 %d", n)
	}
	if max, _ := env.sums.MaxLevel(context.Background(), env.book.ID); max != 0 {
		t.Fatalf("摘要应被清空，实际最高 %d 层", max)
	}
	if _, err := env.states.Get(context.Background(), env.book.ID); err == nil {
		t.Fatal("状态应被删除")
	}
	st, err := env.svc.IndexStatus(context.Background(), env.book.ID)
	if err != nil {
		t.Fatalf("删除后查状态不应报错: %v", err)
	}
	if st.Status != domain.AIIndexIdle {
		t.Fatalf("删除后状态应为 idle，实际 %q", st.Status)
	}
}

// ── 轻量摘要 ────────────────────────────────────────────────────

// 只想看几章讲了什么时，不该建立完整索引（既慢又要钱）。
func TestSummarizeChaptersDoesNotBuildIndex(t *testing.T) {
	env := newAIEnv(t, 5, simpleAIConfig())

	out, err := env.svc.SummarizeChapters(context.Background(), env.book.ID, 1, 2)
	if err != nil {
		t.Fatalf("生成摘要失败: %v", err)
	}
	if strings.TrimSpace(out) == "" {
		t.Fatal("摘要不应为空")
	}
	if n, _ := env.chunks.Count(context.Background(), env.book.ID); n != 0 {
		t.Fatalf("轻量路径不应写切片，实际 %d 片", n)
	}
	if max, _ := env.sums.MaxLevel(context.Background(), env.book.ID); max != 0 {
		t.Fatalf("轻量路径不应写摘要表，实际最高 %d 层", max)
	}
	if chat, _ := env.llm.counts(); chat != 1 {
		t.Fatalf("区间摘要应只调一次模型，实际 %d 次", chat)
	}

	// 送进去的必须只有选中的两章，多送一章就是白花钱。
	inputs := env.llm.inputs()
	if len(inputs) != 1 {
		t.Fatalf("应只记录一次输入，实际 %d", len(inputs))
	}
	if !strings.Contains(inputs[0], "第2章") || !strings.Contains(inputs[0], "第3章") {
		t.Fatalf("输入应包含第 2、3 章：%q", inputs[0])
	}
	if strings.Contains(inputs[0], "第1章") || strings.Contains(inputs[0], "第4章") {
		t.Fatalf("输入不应包含区间外的章节：%q", inputs[0])
	}
}

func TestSummarizeChaptersRejectsBadRange(t *testing.T) {
	env := newAIEnv(t, 3, simpleAIConfig())
	if _, err := env.svc.SummarizeChapters(context.Background(), env.book.ID, 2, 1); err == nil {
		t.Fatal("起点大于终点时应报错")
	}
	if _, err := env.svc.SummarizeChapters(context.Background(), env.book.ID, 0, 99); err == nil {
		t.Fatal("越界时应报错")
	}
}

func TestSummarizeChaptersWithoutConfig(t *testing.T) {
	env := newAIEnv(t, 3, nil)
	if _, err := env.svc.SummarizeChapters(context.Background(), env.book.ID, 0, 1); err == nil {
		t.Fatal("未配置时应报错")
	}
}

// ── 参数校验 ────────────────────────────────────────────────────

func TestIndexRejectsMissingBookID(t *testing.T) {
	env := newAIEnv(t, 1, simpleAIConfig())
	if _, err := env.svc.StartIndex(context.Background(), 0, domain.AIScopeAll, 0, 0); err == nil {
		t.Fatal("缺书籍 ID 时应报错")
	}
	if _, err := env.svc.IndexStatus(context.Background(), 0); err == nil {
		t.Fatal("缺书籍 ID 时应报错")
	}
	if err := env.svc.DeleteIndex(context.Background(), 0); err == nil {
		t.Fatal("缺书籍 ID 时应报错")
	}
}
