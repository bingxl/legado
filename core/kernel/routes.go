package kernel

import (
	"context"
	"net/http"
	"strings"
)

// CommandFunc 是 CLI 子命令的实现。
type CommandFunc func(ctx context.Context, args []string) error

// Command 是一个已注册的 CLI 命令（path 形如 "source probe"，多级用空格分隔）。
type Command struct {
	Path string `json:"path"`
	Doc  string `json:"doc,omitempty"`
	Run  CommandFunc
}

// Route 是一条 HTTP 路由。
type Route struct {
	Method  string
	Path    string
	Handler http.HandlerFunc
}

// Command 注册 CLI 命令。路径分级的解析交给 hosts/cli，
// 注册表只负责收集 —— 这样模块不需要知道命令行框架。
func (r *Registry) Command(path string, run CommandFunc, doc string) *Command {
	path = strings.TrimSpace(path)
	c := &Command{Path: path, Run: run, Doc: doc}
	r.mu.Lock()
	r.commands[path] = c
	r.mu.Unlock()
	return c
}

// Commands 返回全部命令（按路径排序）。
func (r *Registry) Commands() []Command {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Command, 0, len(r.commands))
	for _, c := range r.commands {
		out = append(out, *c)
	}
	return out
}

// LookupCommand 查找命令。
func (r *Registry) LookupCommand(path string) (*Command, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	c, ok := r.commands[strings.TrimSpace(path)]
	return c, ok
}

// Route 注册 HTTP 路由。
func (r *Registry) Route(method, path string, h http.HandlerFunc) {
	r.mu.Lock()
	r.routes = append(r.routes, Route{Method: strings.ToUpper(method), Path: path, Handler: h})
	r.mu.Unlock()
}

// Routes 返回全部路由。
func (r *Registry) Routes() []Route {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Route, len(r.routes))
	copy(out, r.routes)
	return out
}
