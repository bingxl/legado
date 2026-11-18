package kernel

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
)

// Env 是运行环境。用显式结构替代散落的全局变量与 os.Getenv，
// 便于测试注入临时目录与假时钟。
type Env struct {
	// Root 是数据根目录（数据库、封面、缓存都在它下面）。
	Root string
	// UserAgent 是书源请求与验证窗口共用的 UA。
	UserAgent string
	// Version 用于 FFI 握手与关于页。
	Version string
}

// Module 是功能模块的唯一契约。
//
// 模块构造时注入依赖（由 Boot 装配），Register 时把能力交给注册表。
// 这样「构造」与「注册」分离，既支持按需裁剪模块（测试只启必需模块），
// 也避免 init() 里做副作用。
type Module interface {
	Name() string
	DependsOn() []string
	Register(r *Registry)
}

// Migrator 是可选的迁移钩子。当前 schema 由 sqlite 适配器统一管理，
// 新模块（RSS / TTS / 书签等）需要建表时实现它，不要运行时 CREATE TABLE。
type Migrator interface {
	Migrate(ctx context.Context) error
}

// App 是一次装配的产物：注册表 + 环境 + 需要收尾的资源。
type App struct {
	*Registry
	Env Env

	mu      sync.Mutex
	closers []func()
}

// OnClose 注册收尾函数（LIFO 执行）。
func (a *App) OnClose(f func()) {
	if f == nil {
		return
	}
	a.mu.Lock()
	a.closers = append(a.closers, f)
	a.mu.Unlock()
}

// Close 逆序执行收尾函数。
func (a *App) Close() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	var firstErr error
	for i := len(a.closers) - 1; i >= 0; i-- {
		if err := runCloser(a.closers[i]); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	a.closers = nil
	return firstErr
}

func runCloser(f func()) (err error) {
	defer func() {
		if rec := recover(); rec != nil {
			err = fmt.Errorf("收尾时 panic: %v", rec)
		}
	}()
	f()
	return nil
}

// Boot 是三个宿主共用的装配入口：拓扑排序后依次注册。
//
// 顺序只由 DependsOn 决定，与传入顺序无关 —— 所以模块可以放心地
// 各自 append 到同一个列表，不影响正确性。
func Boot(env Env, mods ...Module) (*App, error) {
	ordered, err := topoSort(mods)
	if err != nil {
		return nil, err
	}
	reg := NewRegistry()
	for _, m := range ordered {
		m.Register(reg)
	}
	// 内核自带方法：方法表导出。任何宿主都能拉契约，无需额外接口。
	reg.Method("System.Methods", func(ctx context.Context, args []json.RawMessage) (any, error) {
		return reg.Methods(), nil
	}, Doc("导出全部方法元数据"))
	return &App{Registry: reg, Env: env}, nil
}

// topoSort 按 DependsOn 做稳定拓扑排序（同层保持传入顺序）。
func topoSort(mods []Module) ([]Module, error) {
	byName := make(map[string]Module, len(mods))
	for _, m := range mods {
		if m == nil {
			continue
		}
		if _, dup := byName[m.Name()]; dup {
			return nil, Ef(CodeInternal, "模块重复注册: %s", m.Name())
		}
		byName[m.Name()] = m
	}

	const (
		white = 0
		gray  = 1
		black = 2
	)
	state := make(map[string]int, len(byName))
	out := make([]Module, 0, len(byName))

	var visit func(name string, path []string) error
	visit = func(name string, path []string) error {
		m, ok := byName[name]
		if !ok {
			return Ef(CodeInternal, "模块 %s 依赖了不存在的模块: %v", path[len(path)-1], name)
		}
		switch state[name] {
		case black:
			return nil
		case gray:
			return Ef(CodeInternal, "模块依赖成环: %v -> %s", path, name)
		}
		state[name] = gray
		for _, dep := range m.DependsOn() {
			if err := visit(dep, append(path, name)); err != nil {
				return err
			}
		}
		state[name] = black
		out = append(out, m)
		return nil
	}

	for _, m := range mods {
		if m == nil {
			continue
		}
		if err := visit(m.Name(), []string{m.Name()}); err != nil {
			return nil, err
		}
	}
	return out, nil
}
