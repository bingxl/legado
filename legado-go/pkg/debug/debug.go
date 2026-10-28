// Package debug 复刻 legado 的书源调试日志（Kotlin 的 io.legado.app.model.Debug）。
//
// 与客户端保持一致的约定：
//
//   - 每行以相对调试起点的 [mm:ss.SSS] 开头
//   - state 语义：1 普通 / -1 错误 / 10 搜索列表响应体 / 20 详情页响应体 /
//     30 目录页响应体 / 40 正文页响应体 / 1000 解析完成
//   - 树状符号：≡ 提示、︾/︽ 阶段起止、┌/└ 规则组、◇ 统计
//
// 客户端把 state 10/20/30/40 的响应体单独留给"查看源码"按钮，不混进日志列表；
// 这里同样把它们作为独立记录交给 Sink，由 Sink 决定是打印、截断还是写文件。
//
// 并发安全：下载是并发抓取，所有写入串行化；成组的日志（Pair/Lines）保证不与
// 其他 goroutine 的记录交错。
package debug

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// state 取值，对齐 Kotlin 的 Debug.log(state)
const (
	StateLog         = 1    // 普通日志
	StateError       = -1   // 错误（客户端用红色显示）
	StateSearchBody  = 10   // 搜索/发现列表页响应体
	StateInfoBody    = 20   // 详情页响应体
	StateTocBody     = 30   // 目录页响应体
	StateContentBody = 40   // 正文页响应体
	StateDone        = 1000 // 解析完成
)

// Entry 一条调试记录
type Entry struct {
	Elapsed time.Duration // 相对调试起点的时间，用于生成 [mm:ss.SSS]
	State   int
	Msg     string
}

// IsBody 判断是否响应体记录（state 10/20/30/40）
func (e Entry) IsBody() bool {
	switch e.State {
	case StateSearchBody, StateInfoBody, StateTocBody, StateContentBody:
		return true
	}
	return false
}

// Sink 调试输出目的地。实现可以是终端文本、JSONL、文件落盘，或它们的组合。
// Emit 在包的互斥锁内被调用，实现不必自己加锁，但不要做长时间阻塞的事情。
type Sink interface {
	Emit(Entry)
}

var (
	mu    sync.Mutex
	sink  Sink
	on    atomic.Bool
	start = time.Now()
)

// Enabled 报告是否已启用调试。未启用时所有打点只付一次原子读的代价。
func Enabled() bool { return on.Load() }

// SetSink 启用调试并重置计时起点；传 nil 关闭。
func SetSink(s Sink) {
	mu.Lock()
	sink = s
	start = time.Now()
	mu.Unlock()
	on.Store(s != nil)
}

// Log 输出一条普通日志
func Log(msg string) { Emit(StateLog, msg) }

// Logf 输出一条带格式的普通日志
func Logf(format string, args ...any) {
	if !on.Load() {
		return
	}
	Emit(StateLog, fmt.Sprintf(format, args...))
}

// Error 输出错误日志（客户端 red）
func Error(msg string) { Emit(StateError, msg) }

// Errorf 输出带格式的错误日志
func Errorf(format string, args ...any) {
	if !on.Load() {
		return
	}
	Emit(StateError, fmt.Sprintf(format, args...))
}

// Done 输出"解析完成"（客户端 green）
func Done(msg string) { Emit(StateDone, msg) }

// Body 记录某一步的原始响应，state 取 State*Body
func Body(state int, body string) { Emit(state, body) }

// Emit 写入一条记录
func Emit(state int, msg string) {
	if !on.Load() {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	emitLocked(state, msg)
}

// Lines 连续输出多条普通日志，保证不与其他 goroutine 的记录交错
func Lines(msgs ...string) {
	if !on.Load() || len(msgs) == 0 {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	for _, m := range msgs {
		emitLocked(StateLog, m)
	}
}

// Pair 输出一组 ┌label / └val（对齐 Kotlin 里成对出现的规则日志）
func Pair(label, val string) {
	if !on.Load() {
		return
	}
	mu.Lock()
	defer mu.Unlock()
	emitLocked(StateLog, "┌"+label)
	emitLocked(StateLog, "└"+val)
}

func emitLocked(state int, msg string) {
	if sink == nil {
		return
	}
	sink.Emit(Entry{Elapsed: time.Since(start), State: state, Msg: msg})
}

// —— 不进日志流的杂项 ——

// StateName 返回 state 的可读名，用于 JSON 输出与文件名
func StateName(state int) string {
	switch state {
	case StateError:
		return "error"
	case StateSearchBody:
		return "list"
	case StateInfoBody:
		return "info"
	case StateTocBody:
		return "toc"
	case StateContentBody:
		return "content"
	case StateDone:
		return "done"
	}
	return "log"
}
