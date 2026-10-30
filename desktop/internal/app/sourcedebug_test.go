package app

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// ── 替身 ────────────────────────────────────────────────────

type fakeDebugger struct {
	mu        sync.Mutex
	calls     int
	lastKey   string
	lastStage string
	lastURL   string
	entries   []port.DebugEntry
	result    port.DebugResult
	err       error
	block     chan struct{} // 非 nil 时 Debug 会等它关闭，用来测「上一会话未结束」
}

func (f *fakeDebugger) Debug(ctx context.Context, src *domain.BookSource, key, stage string, sink port.DebugSink) (port.DebugResult, error) {
	f.mu.Lock()
	f.calls++
	f.lastKey = key
	f.lastStage = stage
	f.lastURL = src.URL
	entries := append([]port.DebugEntry(nil), f.entries...)
	result, err := f.result, f.err
	block := f.block
	f.mu.Unlock()

	for _, e := range entries {
		if ctx.Err() != nil {
			return result, ctx.Err()
		}
		sink.Emit(e)
	}
	if block != nil {
		<-block
	}
	return result, err
}

func (f *fakeDebugger) snapshot() (int, string, string, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, f.lastKey, f.lastStage, f.lastURL
}

type fakeEventBus struct {
	mu     sync.Mutex
	events []struct {
		Name    string
		Payload any
	}
}

func (b *fakeEventBus) Emit(_ context.Context, name string, payload any) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.events = append(b.events, struct {
		Name    string
		Payload any
	}{name, payload})
	return nil
}

func (b *fakeEventBus) byName(name string) []any {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := make([]any, 0, len(b.events))
	for _, e := range b.events {
		if e.Name == name {
			out = append(out, e.Payload)
		}
	}
	return out
}

// sourceStub 满足 sourceByID。
type sourceStub struct {
	view dto.SourceView
	err  error
}

func (s sourceStub) Get(context.Context, int64) (dto.SourceView, error) {
	return s.view, s.err
}

const draftJSON = `{"bookSourceUrl":"https://example.com","bookSourceName":"示例源","ruleSearch":{"bookList":"@css:.item"}}`

func newDebugFixture(t *testing.T, dbg *fakeDebugger) (*SourceDebugService, *fakeEventBus) {
	t.Helper()
	bus := &fakeEventBus{}
	svc := NewSourceDebugService(SourceDebugDeps{
		Sources:  sourceStub{view: dto.SourceView{ID: 7, Name: "库里源", URL: "https://saved.example.com", Raw: draftJSON}},
		Debugger: dbg,
		Events:   bus,
	})
	return svc, bus
}

// waitEvents 等事件条数达到 n（或超时），避免依赖固定 sleep。
func waitEvents(t *testing.T, bus *fakeEventBus, name string, n int) []any {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if got := bus.byName(name); len(got) >= n {
			return got
		}
		time.Sleep(5 * time.Millisecond)
	}
	return bus.byName(name)
}

// ── 用例 ────────────────────────────────────────────────────

func TestSourceDebug_UsesDraftRawInsteadOfSaved(t *testing.T) {
	dbg := &fakeDebugger{entries: []port.DebugEntry{{State: port.DebugStateLog, Msg: "⇒开始搜索关键字:剑来"}}}
	svc, bus := newDebugFixture(t, dbg)

	// 传了 raw 就必须用草稿，哪怕库里有同 ID 的旧内容。
	view, err := svc.Start(context.Background(), 7, draftJSON, "剑来", port.DebugStageContent)
	if err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	if view.Session == "" || !view.Running {
		t.Fatalf("会话视图不对: %+v", view)
	}

	entries := waitEvents(t, bus, port.EventSourceDebug, 1)
	if len(entries) == 0 {
		t.Fatal("没有收到 source:debug 事件")
	}
	_, key, stage, srcURL := dbg.snapshot()
	if key != "剑来" || stage != port.DebugStageContent {
		t.Fatalf("入口/阶段传错: key=%q stage=%q", key, stage)
	}
	if srcURL != "https://example.com" {
		t.Fatalf("应当使用草稿里的地址，实际 %q", srcURL)
	}
}

// waitCalled 等调试器真的被调用（Start 是异步的）。
func waitCalled(t *testing.T, dbg *fakeDebugger) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if calls, _, _, _ := dbg.snapshot(); calls > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("调试器没有被调用")
}

func TestSourceDebug_FallsBackToSavedSource(t *testing.T) {
	dbg := &fakeDebugger{}
	svc, _ := newDebugFixture(t, dbg)

	if _, err := svc.Start(context.Background(), 7, "", "剑来", port.DebugStageSearch); err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	waitCalled(t, dbg)
	_, _, stage, srcURL := dbg.snapshot()
	if srcURL != "https://saved.example.com" {
		t.Fatalf("应当使用库里的地址，实际 %q", srcURL)
	}
	if stage != port.DebugStageSearch {
		t.Fatalf("阶段传错: %q", stage)
	}
}

func TestSourceDebug_RejectsBadInput(t *testing.T) {
	svc, _ := newDebugFixture(t, &fakeDebugger{})

	if _, err := svc.Start(context.Background(), 0, "", "剑来", "content"); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("缺少书源时应报参数错误，实际 %v", err)
	}
	if _, err := svc.Start(context.Background(), 0, "{不是 json", "剑来", "content"); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("非法 JSON 应报参数错误，实际 %v", err)
	}
	if _, err := svc.Start(context.Background(), 0, `{"bookSourceName":"无地址"}`, "剑来", "content"); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("缺 bookSourceUrl 应报参数错误，实际 %v", err)
	}
	if _, err := svc.Start(context.Background(), 7, "", "   ", "content"); !errors.Is(err, domain.ErrInvalidArgument) {
		t.Fatalf("空入口应报参数错误，实际 %v", err)
	}
}

func TestSourceDebug_EmitsEntriesAndDone(t *testing.T) {
	dbg := &fakeDebugger{
		entries: []port.DebugEntry{
			{ElapsedMS: 1, State: port.DebugStateLog, Msg: "︾开始解析搜索页"},
			{ElapsedMS: 5, State: port.DebugStateSearchBody, Msg: "<html>...</html>"},
			{ElapsedMS: 9, State: port.DebugStateError, Msg: "⇒详情页失败"},
		},
		result: port.DebugResult{Failed: true, Reason: "详情页失败: 未匹配到节点"},
	}
	svc, bus := newDebugFixture(t, dbg)

	if _, err := svc.Start(context.Background(), 7, "", "剑来", "content"); err != nil {
		t.Fatalf("Start 失败: %v", err)
	}

	entries := waitEvents(t, bus, port.EventSourceDebug, 3)
	if len(entries) != 3 {
		t.Fatalf("期望 3 条打点，实际 %d", len(entries))
	}
	second, ok := entries[1].(dto.DebugEntryView)
	if !ok {
		t.Fatalf("打点类型不对: %T", entries[1])
	}
	if second.StateName != "list" {
		t.Fatalf("响应体状态名应为 list，实际 %q", second.StateName)
	}

	done := waitEvents(t, bus, port.EventSourceDebugDone, 1)
	if len(done) != 1 {
		t.Fatal("没有收到结束事件")
	}
	view := done[0].(dto.DebugDoneView)
	if !view.Failed || !strings.Contains(view.Reason, "详情页失败") {
		t.Fatalf("结束事件应标记失败并带原因: %+v", view)
	}

	// 结束后 Running 应当回到空闲。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && svc.Running().Running {
		time.Sleep(5 * time.Millisecond)
	}
	if svc.Running().Running {
		t.Fatal("调试结束后仍报告运行中")
	}
}

func TestSourceDebug_CapsEntryCount(t *testing.T) {
	entries := make([]port.DebugEntry, 0, debugMaxEntries+50)
	for i := 0; i < debugMaxEntries+50; i++ {
		entries = append(entries, port.DebugEntry{State: port.DebugStateLog, Msg: fmt.Sprintf("第 %d 行", i)})
	}
	dbg := &fakeDebugger{entries: entries}
	svc, bus := newDebugFixture(t, dbg)

	if _, err := svc.Start(context.Background(), 7, "", "剑来", "content"); err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	// 上限之外只额外补一条「已省略」提示。
	got := waitEvents(t, bus, port.EventSourceDebug, debugMaxEntries+1)
	if len(got) != debugMaxEntries+1 {
		t.Fatalf("期望 %d 条（含一条省略提示），实际 %d", debugMaxEntries+1, len(got))
	}
	last := got[len(got)-1].(dto.DebugEntryView)
	if !strings.Contains(last.Msg, "已省略") {
		t.Fatalf("最后一条应为省略提示，实际 %q", last.Msg)
	}
}

func TestSourceDebug_StopCancelsPreviousSession(t *testing.T) {
	dbg := &fakeDebugger{block: make(chan struct{})}
	svc, _ := newDebugFixture(t, dbg)

	first, err := svc.Start(context.Background(), 7, "", "剑来", "content")
	if err != nil {
		t.Fatalf("Start 失败: %v", err)
	}
	// 让第一次调试真的进到 Debug 里。
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if calls, _, _, _ := dbg.snapshot(); calls > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	svc.Stop()
	close(dbg.block) // 放行被阻塞的调试

	// 停止后可以立刻再起一次，且不是同一个会话。
	start := time.Now()
	second, err := svc.Start(context.Background(), 7, "", "斗破", "search")
	if err != nil {
		t.Fatalf("重启失败: %v", err)
	}
	if second.Session == first.Session {
		t.Fatal("重启后会话 ID 不应沿用旧的")
	}
	if elapsed := time.Since(start); elapsed > debugStopWait+2*time.Second {
		t.Fatalf("重启耗时过长: %v", elapsed)
	}
}
