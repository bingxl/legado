// Package eventwails 用 Wails 的事件机制实现 port.EventBus。
//
// 这一层是「依赖倒置」的落点：app 层只面向 port.EventBus 接口编程，
// 不需要 import Wails（ARCHITECTURE.md R2），而真正的 Wails 依赖被隔离在此。
package eventwails

import (
	"context"
	"sync"

	"github.com/wailsapp/wails/v3/pkg/application"
)

// Bus 实现 port.EventBus。
type Bus struct {
	mu  sync.RWMutex
	app *application.App
	// pending 缓存在 App 就绪前收到的事件，就绪后补发。
	// 这样服务层不必关心启动时序。
	pending []pendingEvent
}

type pendingEvent struct {
	name    string
	payload any
}

// New 创建事件总线。
func New() *Bus { return &Bus{} }

// Attach 绑定 Wails 应用实例，并补发此前缓存的事件。
func (b *Bus) Attach(app *application.App) {
	if app == nil {
		return
	}
	b.mu.Lock()
	b.app = app
	queued := b.pending
	b.pending = nil
	b.mu.Unlock()

	for _, e := range queued {
		app.Event.Emit(e.name, e.payload)
	}
}

// Emit 广播事件；App 尚未就绪时先缓存。
func (b *Bus) Emit(ctx context.Context, name string, payload any) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	b.mu.RLock()
	app := b.app
	b.mu.RUnlock()

	if app == nil {
		b.mu.Lock()
		b.pending = append(b.pending, pendingEvent{name: name, payload: payload})
		b.mu.Unlock()
		return nil
	}
	app.Event.Emit(name, payload)
	return nil
}
