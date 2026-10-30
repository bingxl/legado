package app

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceDebugService 在后台跑一次书源调试，把打点实时推给前端。
//
// 与「校验」的区别：校验只看规则是否写全（可纯本地完成），
// 调试是真发请求、真跑规则，把每一步的求值过程按顺序打出来。
// 因此调试必然是异步的：一次完整链路（搜索→详情→目录→正文）要几十秒。
type SourceDebugService struct {
	sources  sourceByID
	debugger port.SourceDebugger
	events   port.EventBus

	mu       sync.Mutex
	session  string
	cancel   context.CancelFunc
	done     chan struct{}
	started  time.Time
	emitted  int
	overflow bool
}

// sourceByID 是调试服务对书源仓库的最小依赖。
//
// 直接复用 SourceService 的 Get，避免再往仓库层写一遍查询。
type sourceByID interface {
	Get(ctx context.Context, id int64) (dto.SourceView, error)
}

// SourceDebugDeps 聚合调试服务的依赖。
type SourceDebugDeps struct {
	Sources  sourceByID
	Debugger port.SourceDebugger
	Events   port.EventBus
}

// NewSourceDebugService 构造书源调试服务。
func NewSourceDebugService(d SourceDebugDeps) *SourceDebugService {
	return &SourceDebugService{sources: d.Sources, debugger: d.Debugger, events: d.Events}
}

const (
	// debugStopWait 是「重启调试」时等上一次会话退出的上限。
	// 引擎不接 context，卡在 HTTP 请求上时只能等它自己结束；
	// 与其无限等，不如明确告诉用户「上一次还在跑」。
	debugStopWait = 3 * time.Second
	// debugMaxEntries 是一次会话最多推送的打点条数。
	// 书源里写了死循环的 js 能刷出几十万行，不设上限会把事件通道打爆。
	debugMaxEntries = 2000
)

// Start 启动一次调试。
//
// rawJSON 非空时以它为准（编辑页里改了字段还没保存，也能直接调试）；
// 为空时按 sourceID 取库里已保存的书源。
// key 是调试入口：关键字 / 书籍地址 / 分类::地址 / ++目录地址 / --正文地址。
func (s *SourceDebugService) Start(ctx context.Context, sourceID int64, rawJSON string, key string, stage string) (dto.DebugSessionView, error) {
	src, err := s.resolveSource(ctx, sourceID, rawJSON)
	if err != nil {
		return dto.DebugSessionView{}, err
	}
	if strings.TrimSpace(key) == "" {
		return dto.DebugSessionView{}, fmt.Errorf("%w: 请填写调试入口（书名、书籍地址或 分类::地址）", domain.ErrInvalidArgument)
	}

	// 同一时刻只允许一个会话：引擎的 sink 是进程级的，且前端的输出面板也只有一块。
	s.stopRunning()

	runCtx, cancel := context.WithCancel(context.Background()) // 绑定方法返回后请求 ctx 会被取消
	done := make(chan struct{})
	session := fmt.Sprintf("%d", time.Now().UnixNano())

	s.mu.Lock()
	s.session = session
	s.cancel = cancel
	s.done = done
	s.started = time.Now()
	s.emitted = 0
	s.overflow = false
	s.mu.Unlock()

	go s.run(runCtx, session, src, key, stage, done)
	return dto.DebugSessionView{Session: session, Running: true}, nil
}

// Stop 取消当前调试。引擎会在当前阶段结束后自行退出，因此这里不等。
func (s *SourceDebugService) Stop() {
	s.mu.Lock()
	cancel := s.cancel
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

// Running 报告当前是否有调试在跑，并返回会话 ID。
func (s *SourceDebugService) Running() dto.DebugSessionView {
	s.mu.Lock()
	defer s.mu.Unlock()
	return dto.DebugSessionView{Session: s.session, Running: s.cancel != nil}
}

// resolveSource 决定本次调试用哪份书源。
func (s *SourceDebugService) resolveSource(ctx context.Context, sourceID int64, rawJSON string) (*domain.BookSource, error) {
	raw := strings.TrimSpace(rawJSON)
	if raw != "" {
		var probe map[string]any
		if err := json.Unmarshal([]byte(raw), &probe); err != nil {
			return nil, fmt.Errorf("%w: 书源 JSON 解析失败: %v", domain.ErrInvalidArgument, err)
		}
		src := &domain.BookSource{Raw: raw}
		fillSourceFromRaw(src)
		if src.URL == "" {
			return nil, fmt.Errorf("%w: 书源地址（bookSourceUrl）不能为空", domain.ErrInvalidArgument)
		}
		// 调试按 bookSourceUrl 决定 @get/@put 的变量作用域，必须带上。
		return src, nil
	}
	if sourceID == 0 {
		return nil, fmt.Errorf("%w: 缺少书源 ID", domain.ErrInvalidArgument)
	}
	view, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	src := &domain.BookSource{ID: view.ID, Name: view.Name, Group: view.Group, URL: view.URL, Enabled: view.Enabled, Raw: view.Raw}
	return src, nil
}

// run 执行调试并把打点转成事件。
func (s *SourceDebugService) run(ctx context.Context, session string, src *domain.BookSource, key, stage string, done chan struct{}) {
	defer close(done)
	defer func() {
		s.mu.Lock()
		if s.session == session {
			s.cancel = nil
			s.done = nil
		}
		s.mu.Unlock()
	}()

	started := time.Now()
	result, err := s.debugger.Debug(ctx, src, key, stage, &eventSinkAdapter{svc: s, session: session})

	doneView := dto.DebugDoneView{
		Session:   session,
		Failed:    result.Failed || err != nil,
		Reason:    result.Reason,
		ElapsedMS: time.Since(started).Milliseconds(),
	}
	if err != nil {
		if ctx.Err() != nil {
			doneView.Reason = "已停止"
		} else {
			doneView.Reason = err.Error()
		}
	}
	s.emit(port.EventSourceDebugDone, doneView)
}

// eventSinkAdapter 把 port.DebugSink 桥接到事件总线，同时做条数限制。
type eventSinkAdapter struct {
	svc     *SourceDebugService
	session string
}

func (a *eventSinkAdapter) Emit(e port.DebugEntry) {
	a.svc.mu.Lock()
	if a.svc.session != a.session {
		a.svc.mu.Unlock()
		return // 会话已被新的调试顶替，旧打点丢弃
	}
	if a.svc.emitted >= debugMaxEntries {
		overflowed := a.svc.overflow
		a.svc.overflow = true
		a.svc.mu.Unlock()
		if !overflowed {
			a.svc.emit(port.EventSourceDebug, dto.DebugEntryView{
				Session:   a.session,
				ElapsedMS: e.ElapsedMS,
				State:     port.DebugStateError,
				StateName: "error",
				Msg:       fmt.Sprintf("日志条数超过 %d，后续输出已省略", debugMaxEntries),
			})
		}
		return
	}
	a.svc.emitted++
	a.svc.mu.Unlock()

	a.svc.emit(port.EventSourceDebug, dto.NewDebugEntryView(a.session, e))
}

func (s *SourceDebugService) emit(name string, payload any) {
	if s.events == nil {
		return
	}
	_ = s.events.Emit(context.Background(), name, payload)
}

// stopRunning 停掉正在跑的调试并等它退出。
func (s *SourceDebugService) stopRunning() {
	s.mu.Lock()
	cancel, done := s.cancel, s.done
	s.mu.Unlock()
	if cancel == nil {
		return
	}
	cancel()
	if done == nil {
		return
	}
	select {
	case <-done:
	case <-time.After(debugStopWait):
		// 超时也继续：适配器里的全局锁会让新会话排队，直到旧会话真的退出。
	}
}

// fillSourceFromRaw 从书源 JSON 抽出版本管理用的几个字段。
//
// 与 SourceService 保存时用的是同一套取值口径（bookSourceName 等），
// 这里只取调试必需的 URL/名称——少了它，引擎无法决定变量作用域与来源标注。
func fillSourceFromRaw(src *domain.BookSource) {
	var m map[string]any
	if err := json.Unmarshal([]byte(src.Raw), &m); err != nil {
		return
	}
	pick := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
				return v
			}
		}
		return ""
	}
	if src.URL == "" {
		src.URL = pick("bookSourceUrl", "url")
	}
	if src.Name == "" {
		src.Name = pick("bookSourceName", "name")
	}
	if src.Group == "" {
		src.Group = pick("bookSourceGroup", "group")
	}
}
