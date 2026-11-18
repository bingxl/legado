// Package kernel 是 core 的机制层：模块注册表、方法分发、Trace 事件、统一错误。
//
// 设计目标（见 docs/ARCHITECTURE-V2.md §4）：业务模块只在自己的 Register() 里
// 声明能力，CLI / FFI / HTTP 三种宿主自动获得，新增模块不改任何宿主代码。
package kernel

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
)

// Handler 是方法的具体实现。
//
// args 是已定位的参数数组（按 Go 方法的参数顺序，context 除外），
// 由 Registry 统一从 JSON 解出，模块不需要自己处理报文格式。
type Handler func(ctx context.Context, args []json.RawMessage) (any, error)

// Method 是一个已注册的方法。元数据用于 `legado schema` 导出，
// Dart 侧据此生成方法常量与参数个数校验。
type Method struct {
	Name        string   `json:"name"`
	Doc         string   `json:"doc,omitempty"`
	Arity       int      `json:"arity"`
	ParamTypes  []string `json:"paramTypes,omitempty"`
	ResultTypes []string `json:"resultTypes,omitempty"`
	Streaming   bool     `json:"streaming,omitempty"`

	handler Handler
}

// Registry 是模块与宿主之间唯一的防腐层。
type Registry struct {
	mu       sync.RWMutex
	methods  map[string]*Method
	order    []string
	commands map[string]*Command
	routes   []Route
}

// NewRegistry 创建空注册表。
func NewRegistry() *Registry {
	return &Registry{
		methods:  make(map[string]*Method),
		commands: make(map[string]*Command),
	}
}

// Add 注册一个方法。重复注册会覆盖并保留首次的顺序。
func (r *Registry) Add(m *Method) *Method {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, ok := r.methods[m.Name]; !ok {
		r.order = append(r.order, m.Name)
	}
	r.methods[m.Name] = m
	return m
}

// Method 注册一个手写方法，返回 *Method 以便链式补 Describe。
func (r *Registry) Method(name string, h Handler, opt ...MethodOpt) *Method {
	m := &Method{Name: name, handler: h}
	for _, o := range opt {
		o(m)
	}
	return r.Add(m)
}

// MethodOpt 是方法注册的可选项。
type MethodOpt func(*Method)

// Doc 补充方法说明。
func Doc(text string) MethodOpt { return func(m *Method) { m.Doc = text } }

// Sig 声明手写方法的参数类型，用于 `legado schema` 导出。
//
// 反射注册（RegisterService）能自动得到签名；手写 handler 拿不到，
// 必须显式声明，否则 Dart 侧无法生成参数校验。示例：
//
//	r.Method("Rss.Article.List", h, kernel.Sig("sourceId int64", "onlyUnread bool"))
func Sig(params ...string) MethodOpt {
	return func(m *Method) {
		m.ParamTypes = params
		m.Arity = len(params)
	}
}

// Streaming 标记该方法会产生流式输出（trace / 进度）。
func Streaming() MethodOpt { return func(m *Method) { m.Streaming = true } }

// Lookup 查找方法元数据。
func (r *Registry) Lookup(name string) (*Method, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	m, ok := r.methods[name]
	return m, ok
}

// Call 按方法名调用，args 为原始 JSON 参数数组。
func (r *Registry) Call(ctx context.Context, name string, args []json.RawMessage) (any, error) {
	m, ok := r.Lookup(name)
	if !ok {
		return nil, E(CodeNotFound, fmt.Sprintf("方法不存在: %s", name))
	}
	return m.handler(ctx, args)
}

// Methods 按注册顺序返回全部方法元数据（不含 handler）。
func (r *Registry) Methods() []Method {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Method, 0, len(r.order))
	for _, name := range r.order {
		if m, ok := r.methods[name]; ok {
			out = append(out, *m)
		}
	}
	return out
}

// Domains 返回方法名按域聚合的计数，供 schema 与文档使用。
func (r *Registry) Domains() map[string]int {
	out := map[string]int{}
	for _, m := range r.Methods() {
		out[domainOf(m.Name)]++
	}
	return out
}

func domainOf(name string) string {
	for i := 0; i < len(name); i++ {
		if name[i] == '.' {
			return name[:i]
		}
	}
	return name
}

// SortedNames 返回排序后的方法名，便于稳定输出。
func (r *Registry) SortedNames() []string {
	names := make([]string, 0, len(r.order))
	r.mu.RLock()
	for _, n := range r.order {
		names = append(names, n)
	}
	r.mu.RUnlock()
	sort.Strings(names)
	return names
}
