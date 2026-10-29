// Package eventlog 提供一个把事件写入 io.Writer 的 EventBus 实现。
//
// 用途：命令行工具与测试。它们没有 Wails 前端可推送，
// 但仍需观察服务层发出的进度事件（导入进度、书源校验进度、下载进度等）。
package eventlog

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"

	"github.com/legado/desktop/internal/port"
)

// Bus 把事件以 JSON 行写入 w，实现 port.EventBus。
type Bus struct {
	mu sync.Mutex
	w  io.Writer
}

// New 创建一个事件日志总线；w 为 nil 时事件被丢弃。
func New(w io.Writer) *Bus { return &Bus{w: w} }

var _ port.EventBus = (*Bus)(nil)

// Emit 输出一行 "<事件名>\t<payload JSON>"。
//
// 写入失败不返回错误：事件只用于观测，不应影响业务主流程。
func (b *Bus) Emit(_ context.Context, name string, payload any) error {
	if b == nil || b.w == nil {
		return nil
	}
	data, err := json.Marshal(payload)
	if err != nil {
		data = []byte(fmt.Sprintf("<无法序列化: %v>", err))
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	_, err = fmt.Fprintf(b.w, "[event] %s\t%s\n", name, data)
	return err
}
