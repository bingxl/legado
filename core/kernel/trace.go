package kernel

import (
	"sync"
	"sync/atomic"
	"time"
)

// Trace 事件类型。
const (
	KindHTTP  = "http"
	KindRule  = "rule"
	KindJS    = "js"
	KindParse = "parse"
	KindError = "error"
	KindCache = "cache"
	KindTimer = "timer"
)

// Trace 阶段，与原版 legado 调试面板的五段一致。
const (
	StageSearch  = "search"
	StageExplore = "explore"
	StageInfo    = "info"
	StageToc     = "toc"
	StageContent = "content"
)

// TraceEvent 是一条结构化调试事件。
//
// 与旧 `pkg/debug` 的打印不同，这里是**数据**：CLI 渲染成彩色树或 JSONL，
// HTTP 推 SSE，Flutter 调试页按 stage 分组。三者消费同一份，不存在两套逻辑。
type TraceEvent struct {
	Seq    int64     `json:"seq"`
	Kind   string    `json:"kind"`
	Stage  string    `json:"stage,omitempty"`
	Rule   string    `json:"rule,omitempty"`
	Target string    `json:"target,omitempty"`
	URL    string    `json:"url,omitempty"`
	Status int       `json:"status,omitempty"`
	Bytes  int       `json:"bytes,omitempty"`
	Count  int       `json:"count,omitempty"`
	MS     int64     `json:"ms,omitempty"`
	Hit    bool      `json:"hit"`
	Code   string    `json:"code,omitempty"`
	Msg    string    `json:"msg,omitempty"`
	At     time.Time `json:"at"`
}

// TraceBus 是进程内的事件总线。
//
// 有界环形缓冲 + 每个订阅者独立的有界队列：慢消费者丢事件而不是拖住发布者，
// 调试场景丢几条旧事件可以接受，卡住抓取流程不可接受。
type TraceBus struct {
	seq atomic.Int64

	mu   sync.RWMutex
	subs map[int]chan TraceEvent
	next int

	keep int
	buf  []TraceEvent
}

// NewTraceBus 创建事件总线。keep<=0 时默认保留最近 512 条。
func NewTraceBus(keep int) *TraceBus {
	if keep <= 0 {
		keep = 512
	}
	return &TraceBus{subs: map[int]chan TraceEvent{}, keep: keep}
}

// Publish 发布一条事件并补齐 seq/At，返回填充后的事件。
func (b *TraceBus) Publish(e TraceEvent) TraceEvent {
	if b == nil {
		return e
	}
	e.Seq = b.seq.Add(1)
	if e.At.IsZero() {
		e.At = time.Now()
	}

	b.mu.Lock()
	b.buf = append(b.buf, e)
	if len(b.buf) > b.keep {
		b.buf = append([]TraceEvent(nil), b.buf[len(b.buf)-b.keep:]...)
	}
	subs := make([]chan TraceEvent, 0, len(b.subs))
	for _, ch := range b.subs {
		subs = append(subs, ch)
	}
	b.mu.Unlock()

	for _, ch := range subs {
		select {
		case ch <- e:
		default: // 慢消费者：丢弃，不阻塞抓取
		}
	}
	return e
}

// Subscribe 订阅事件流，返回取消函数（必须调用，否则泄漏 goroutine）。
func (b *TraceBus) Subscribe() (<-chan TraceEvent, func()) {
	if b == nil {
		ch := make(chan TraceEvent)
		close(ch)
		return ch, func() {}
	}
	ch := make(chan TraceEvent, 256)
	b.mu.Lock()
	id := b.next
	b.next++
	b.subs[id] = ch
	b.mu.Unlock()

	cancel := func() {
		b.mu.Lock()
		if c, ok := b.subs[id]; ok {
			delete(b.subs, id)
			close(c)
		}
		b.mu.Unlock()
	}
	return ch, cancel
}

// Recent 返回缓冲区内的事件副本（用于调试页首屏回填）。
func (b *TraceBus) Recent() []TraceEvent {
	if b == nil {
		return nil
	}
	b.mu.RLock()
	defer b.mu.RUnlock()
	out := make([]TraceEvent, len(b.buf))
	copy(out, b.buf)
	return out
}
