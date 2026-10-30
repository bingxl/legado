package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// 调试打点的状态取值。与 legado-go 的 debug 包一一对应，
// 之所以在这里重新声明，是为了不让 app 层与前端契约依赖第三方常量。
const (
	DebugStateLog         = 1    // 普通日志
	DebugStateError       = -1   // 错误
	DebugStateSearchBody  = 10   // 搜索/发现列表页响应体
	DebugStateInfoBody    = 20   // 详情页响应体
	DebugStateTocBody     = 30   // 目录页响应体
	DebugStateContentBody = 40   // 正文页响应体
	DebugStateDone        = 1000 // 解析完成
)

// 调试链路的最大执行深度：跑到哪一步就停。
const (
	DebugStageSearch  = "search"  // 只跑搜索/发现列表
	DebugStageExplore = "explore" // 只跑发现页
	DebugStageInfo    = "info"    // 跑到详情页
	DebugStageTOC     = "toc"     // 跑到目录页
	DebugStageContent = "content" // 一路跑到正文（默认）
)

// DebugEntry 是一次书源调试中的一条打点。
//
// ElapsedMS 是相对调试起点的毫秒数，前端据此还原 [mm:ss.SSS]；
// State 决定前端着色（错误红、完成绿、响应体灰）。
type DebugEntry struct {
	ElapsedMS int64
	State     int
	Msg       string
}

// DebugSink 接收调试打点。
//
// 实现会在引擎的全局互斥锁内被调用，因此**不要做长时间阻塞的操作**——
// 推事件到前端是可以的，但不要在这里等网络或等锁。
type DebugSink interface {
	Emit(DebugEntry)
}

// DebugResult 汇总一次调试的结果。
//
// 调试过程中的失败（规则匹配不到、网络错误）本身也是一条日志，
// 不算接口错误；只有「根本没跑起来」才通过 error 返回。
type DebugResult struct {
	Failed bool   // 是否在某个阶段失败
	Reason string // 失败原因，Failed 为 false 时为空
}

// SourceDebugger 按入口形态跑一遍书源链路，把过程中的打点交给 sink。
//
// 入口形态与 Legado 客户端一致，由 key 的内容决定：
//   - 普通关键字          搜索，再顺着详情 → 目录 → 正文往下跑
//   - 绝对 URL            从详情页开始
//   - "分类::地址"         发现页（地址为空时按分类名查 exploreUrl）
//   - "++地址"            从目录页开始
//   - "--地址"            从正文页开始
type SourceDebugger interface {
	Debug(ctx context.Context, src *domain.BookSource, key string, stage string, sink DebugSink) (DebugResult, error)
}
