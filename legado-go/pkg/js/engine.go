package js

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"
	"github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/util"
)

// Bindings 一次 JS 求值注入的变量（对齐 legado buildScriptBindings）
type Bindings struct {
	Source         *model.BookSource
	Book           *model.Book
	Chapter        *model.BookChapter
	Result         any
	BaseUrl        string
	Src            any // 原始内容（HTML/JSON 字符串或节点）
	NextChapterUrl string
	Title          string
	Key            string
	Page           *int
	SpeakText      string
	SpeakSpeed     int
	Extra          map[string]any
	// Vars 变量读写（java.put/java.get），由 AnalyzeRule 提供
	Vars VarStore
}

// Engine JS 引擎：按书源隔离运行时 + 脚本编译缓存
type Engine struct {
	mu       sync.Mutex
	pools    map[string]*sync.Pool
	libProg  map[string]*goja.Program
	scripts  map[string]*goja.Program
	scriptN  int
	MaxCache int
	Timeout  time.Duration
}

var defaultEngine = &Engine{
	pools:    map[string]*sync.Pool{},
	libProg:  map[string]*goja.Program{},
	scripts:  map[string]*goja.Program{},
	MaxCache: 512,
	Timeout:  30 * time.Second,
}

// DefaultEngine 全局引擎
func DefaultEngine() *Engine { return defaultEngine }

// SetTimeout 设置单次 JS 执行超时
func (e *Engine) SetTimeout(d time.Duration) {
	e.mu.Lock()
	e.Timeout = d
	e.mu.Unlock()
}

func (e *Engine) pool(key, jsLib string) *sync.Pool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if p, ok := e.pools[key]; ok {
		return p
	}
	// 编译 jsLib（一次）
	var lib *goja.Program
	if strings.TrimSpace(jsLib) != "" {
		p, err := goja.Compile("jsLib", jsLib, false)
		if err == nil {
			lib = p
			e.libProg[key] = p
		}
	}
	p := &sync.Pool{New: func() any {
		vm := goja.New()
		setupGlobals(vm)
		if lib != nil {
			_, _ = vm.RunProgram(lib)
		}
		return vm
	}}
	e.pools[key] = p
	return p
}

// RemovePool 释放某书源的运行时（jsLib 变更时调用）
func (e *Engine) RemovePool(key string) {
	e.mu.Lock()
	delete(e.pools, key)
	delete(e.libProg, key)
	e.mu.Unlock()
}

func (e *Engine) script(jsStr string) (*goja.Program, error) {
	e.mu.Lock()
	if p, ok := e.scripts[jsStr]; ok {
		e.mu.Unlock()
		return p, nil
	}
	e.mu.Unlock()
	p, err := goja.Compile("rule.js", jsStr, false)
	if err != nil {
		return nil, err
	}
	e.mu.Lock()
	if e.scriptN >= e.MaxCache {
		e.scripts = map[string]*goja.Program{}
		e.scriptN = 0
	}
	e.scripts[jsStr] = p
	e.scriptN++
	e.mu.Unlock()
	return p, nil
}

// Eval 执行 JS 并返回 Go 值
func (e *Engine) Eval(jsStr string, b *Bindings) (out any, err error) {
	if strings.TrimSpace(jsStr) == "" {
		return nil, nil
	}
	key := ""
	jsLib := ""
	if b != nil && b.Source != nil {
		key = b.Source.BookSourceUrl
		jsLib = b.Source.JsLib
	}
	prog, cerr := e.script(jsStr)
	if cerr != nil {
		return nil, fmt.Errorf("JS 编译失败: %w", cerr)
	}
	p := e.pool(key, jsLib)
	vm := p.Get().(*goja.Runtime)
	defer func() {
		// 运行时已中断或状态异常则丢弃
		if r := recover(); r != nil {
			err = fmt.Errorf("JS 执行异常: %v", r)
			vm = nil
			return
		}
		if vm != nil {
			p.Put(vm)
		}
	}()

	inject(vm, b)

	if e.Timeout > 0 {
		t := time.AfterFunc(e.Timeout, func() { vm.Interrupt(errTimeout) })
		defer t.Stop()
	}
	v, rerr := vm.RunProgram(prog)
	if rerr != nil {
		return nil, fmt.Errorf("JS 执行失败: %w", rerr)
	}
	return exportValue(v), nil
}

var errTimeout = fmt.Errorf("JS 执行超时")

func exportValue(v goja.Value) any {
	if v == nil {
		return nil
	}
	if v == goja.Null() || v == goja.Undefined() || v == goja.NaN() {
		return nil
	}
	return v.Export()
}

// —— 全局对象 ——

func setupGlobals(vm *goja.Runtime) {
	g := vm.GlobalObject()
	g.Set("globalThis", g)
	console := vm.NewObject()
	for _, name := range []string{"log", "info", "warn", "error", "debug"} {
		n := name
		console.Set(n, func(call goja.FunctionCall) goja.Value {
			parts := make([]string, 0, len(call.Arguments))
			for _, a := range call.Arguments {
				parts = append(parts, fmt.Sprint(exportValue(a)))
			}
			OnLog("[js] " + strings.Join(parts, " "))
			return goja.Undefined()
		})
	}
	g.Set("console", console)
	// 常用全局函数
	g.Set("md5", func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(Md5(fmt.Sprint(exportValue(call.Argument(0)))))
	})
}

// —— 绑定注入 ——

func inject(vm *goja.Runtime, b *Bindings) {
	g := vm.GlobalObject()
	if b == nil {
		b = &Bindings{}
	}
	g.Set("java", newJavaObject(vm, b))
	g.Set("org", newOrgObject(vm))
	// Rhino 提供 Packages.* 直接访问 Java 类；部分书源靠它调 java.util.Arrays
	// 切字节数组（如漫蛙漫画拆 IV 与密文）。
	g.Set("Packages", newPackagesObject(vm))
	g.Set("cookie", newCookieObject(vm))
	g.Set("cache", newCacheObject(vm))

	if b.Source != nil {
		g.Set("source", newSourceObject(vm, b.Source))
	} else {
		g.Set("source", goja.Null())
	}
	if b.Book != nil {
		g.Set("book", newBookObject(vm, b.Book))
	} else {
		g.Set("book", goja.Null())
	}
	if b.Chapter != nil {
		g.Set("chapter", newChapterObject(vm, b.Chapter))
		g.Set("title", vm.ToValue(b.Chapter.Title))
	} else {
		g.Set("chapter", goja.Null())
		g.Set("title", vm.ToValue(b.Title))
	}
	g.Set("result", toJSValue(vm, b.Result))
	g.Set("baseUrl", vm.ToValue(b.BaseUrl))
	g.Set("src", toJSSrc(vm, b.Src))
	g.Set("nextChapterUrl", vm.ToValue(b.NextChapterUrl))
	if b.Key != "" {
		g.Set("key", vm.ToValue(b.Key))
	}
	if b.Page != nil {
		g.Set("page", vm.ToValue(*b.Page))
	}
	if b.SpeakText != "" {
		g.Set("speakText", vm.ToValue(b.SpeakText))
	}
	g.Set("speakSpeed", vm.ToValue(b.SpeakSpeed))
	g.Set("gInt", vm.ToValue(0))
	if b.Extra != nil {
		for k, v := range b.Extra {
			g.Set(k, toJSValue(vm, v))
		}
	}
}

// toJSValue 把 Go 值转成 goja 值；HTML 节点包装为类 jsoup 对象
func toJSValue(vm *goja.Runtime, v any) goja.Value {
	switch t := v.(type) {
	case nil:
		return goja.Null()
	case goja.Value:
		return t
	case *ElementWrap:
		return t.Object(vm)
	case []*ElementWrap:
		// 对齐 jsoup Elements：数组 + text()/attr()/size() 等方法
		return elementsObject(vm, t)
	case []any:
		arr := make([]any, 0, len(t))
		for _, e := range t {
			arr = append(arr, toJSValue(vm, e).Export())
		}
		return vm.ToValue(arr)
	case []string:
		arr := make([]any, 0, len(t))
		for _, e := range t {
			arr = append(arr, e)
		}
		return vm.ToValue(arr)
	case string, bool, int, int64, float64, float32:
		return vm.ToValue(t)
	default:
		return vm.ToValue(t)
	}
}

func toJSSrc(vm *goja.Runtime, v any) goja.Value {
	if v == nil {
		return vm.ToValue("")
	}
	if s, ok := v.(string); ok {
		return vm.ToValue(s)
	}
	if e, ok := v.(*ElementWrap); ok {
		return vm.ToValue(util.Render(e.Node()))
	}
	if arr, ok := v.([]*ElementWrap); ok {
		var sb strings.Builder
		for _, e := range arr {
			sb.WriteString(util.Render(e.Node()))
		}
		return vm.ToValue(sb.String())
	}
	return vm.ToValue(fmt.Sprint(v))
}
