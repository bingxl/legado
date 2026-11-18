package kernel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
)

// 统一错误码。UI 与 CLI 的提示逻辑都基于这些码，不要各自拼字符串。
const (
	CodeNotFound     = "NOT_FOUND"
	CodeInvalid      = "INVALID_ARGUMENT"
	CodeSourceEmpty  = "SOURCE_EMPTY"
	CodeNetTimeout   = "NET_TIMEOUT"
	CodeAuthRequired = "AUTH_REQUIRED"
	CodeUnsupported  = "UNSUPPORTED"
	CodeInternal     = "INTERNAL"
)

// Error 是带错误码的业务错误。
type Error struct {
	Code string `json:"code"`
	Msg  string `json:"msg"`
}

func (e *Error) Error() string { return e.Code + ": " + e.Msg }

// E 构造一个带错误码的错误。
func E(code, msg string) *Error { return &Error{Code: code, Msg: msg} }

// Ef 构造一个格式化错误。
func Ef(code, format string, a ...any) *Error {
	return &Error{Code: code, Msg: fmt.Sprintf(format, a...)}
}

// AsError 把任意 error 归一化为 *Error，未知错误折叠为 INTERNAL。
//
// 顺序：自带错误码的 *Error → 宿主注册的映射器 → 超时/取消 → INTERNAL。
// 映射器用注册而不是在此 import domain：内核是通用基础设施，
// 让它知道 `domain.ErrNotFound` 会把依赖方向倒过来；由组合根（boot）注册才合理。
func AsError(err error) *Error {
	if err == nil {
		return nil
	}
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	for _, m := range errorMappers() {
		if mapped, ok := m(err); ok && mapped != nil {
			return mapped
		}
	}
	// 超时/取消是标准库就能判定的，不必依赖业务包。
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return &Error{Code: CodeNetTimeout, Msg: err.Error()}
	}
	return &Error{Code: CodeInternal, Msg: err.Error()}
}

// errorMapper 由宿主注册，用于把业务错误哨兵翻译成控制面错误码。
type errorMapper func(error) (*Error, bool)

var (
	mapperMu sync.RWMutex
	mappers  []errorMapper
)

// RegisterErrorMapper 注册一个错误映射器。
//
// 只在装配阶段调用（boot 里），运行期不增删，因此读路径用读锁足够。
func RegisterErrorMapper(fn func(error) (*Error, bool)) {
	if fn == nil {
		return
	}
	mapperMu.Lock()
	mappers = append(mappers, fn)
	mapperMu.Unlock()
}

func errorMappers() []errorMapper {
	mapperMu.RLock()
	defer mapperMu.RUnlock()
	if len(mappers) == 0 {
		return nil
	}
	out := make([]errorMapper, len(mappers))
	copy(out, mappers)
	return out
}

// Request 是控制面的统一请求。args 为**位置参数**数组（按 Go 方法参数顺序）。
//
// 说明：Go 反射拿不到参数名，因此这里采用位置参数而非具名对象；
// Dart 侧的方法表（由 `legado schema` 导出）已含参数个数与类型，可自校验。
type Request struct {
	ID     int64             `json:"id,omitempty"`
	Method string            `json:"method"`
	Args   []json.RawMessage `json:"args,omitempty"`
}

// Response 是控制面的统一响应。
type Response struct {
	ID   int64  `json:"id,omitempty"`
	OK   bool   `json:"ok"`
	Data any    `json:"data,omitempty"`
	Err  *Error `json:"err,omitempty"`
}

// Handle 执行一次请求并返回信封。宿主（FFI / HTTP / CLI）都用它，
// 保证错误格式、panic 兜底、JSON 序列化三处完全一致。
func (r *Registry) Handle(ctx context.Context, raw []byte) (out []byte) {
	var req Request
	// panic 兜底放在这一层，而不是各宿主各写一遍：
	// c-shared 与 gomobile 是**进程内**宿主，handler 里一个空指针就会把整个
	// App 带走；HTTP 那边有 net/http 兜着（只断一条连接），三者行为不一致
	// 会导致「桌面小毛病、安卓闪退」这类难查的差异。
	defer func() {
		if rec := recover(); rec != nil {
			out = mustJSON(Response{
				ID:  req.ID,
				Err: Ef(CodeInternal, "方法执行时 panic: %v", rec),
			})
		}
	}()
	if err := json.Unmarshal(raw, &req); err != nil {
		return mustJSON(Response{Err: Ef(CodeInvalid, "请求不是合法 JSON: %v", err)})
	}
	if strings.TrimSpace(req.Method) == "" {
		return mustJSON(Response{ID: req.ID, Err: E(CodeInvalid, "缺少 method")})
	}
	data, err := r.Call(ctx, req.Method, req.Args)
	if err != nil {
		return mustJSON(Response{ID: req.ID, Err: AsError(err)})
	}
	return mustJSON(Response{ID: req.ID, OK: true, Data: data})
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		return []byte(`{"ok":false,"err":{"code":"INTERNAL","msg":"响应序列化失败"}}`)
	}
	return b
}
