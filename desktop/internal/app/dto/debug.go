package dto

import "github.com/legado/desktop/internal/port"

// DebugEntryView 是一条书源调试打点（推给前端的事件负载）。
//
// StateName 是状态的字符串形式，前端不必再认识魔术数字：
// log / error / list / info / toc / content / done。
type DebugEntryView struct {
	Session   string `json:"session"`   // 会话 ID，前端据此过滤掉过期的打点
	ElapsedMS int64  `json:"elapsedMs"` // 相对调试起点的毫秒数
	State     int    `json:"state"`
	StateName string `json:"stateName"`
	Msg       string `json:"msg"`
}

// DebugDoneView 是一次调试会话的收尾事件。
type DebugDoneView struct {
	Session   string `json:"session"`
	Failed    bool   `json:"failed"`
	Reason    string `json:"reason"` // 失败原因，成功时为空
	ElapsedMS int64  `json:"elapsedMs"`
}

// DebugSessionView 是启动调试后立即返回的会话句柄。
type DebugSessionView struct {
	Session string `json:"session"`
	Running bool   `json:"running"`
}

// DebugStateName 把打点状态映射成可读名。
func DebugStateName(state int) string {
	switch state {
	case port.DebugStateError:
		return "error"
	case port.DebugStateSearchBody:
		return "list"
	case port.DebugStateInfoBody:
		return "info"
	case port.DebugStateTocBody:
		return "toc"
	case port.DebugStateContentBody:
		return "content"
	case port.DebugStateDone:
		return "done"
	}
	return "log"
}

// NewDebugEntryView 从端口类型转换事件负载。
func NewDebugEntryView(session string, e port.DebugEntry) DebugEntryView {
	return DebugEntryView{
		Session:   session,
		ElapsedMS: e.ElapsedMS,
		State:     e.State,
		StateName: DebugStateName(e.State),
		Msg:       e.Msg,
	}
}
