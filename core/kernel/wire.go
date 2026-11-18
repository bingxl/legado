package kernel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
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
func AsError(err error) *Error {
	if err == nil {
		return nil
	}
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	return &Error{Code: CodeInternal, Msg: err.Error()}
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
func (r *Registry) Handle(ctx context.Context, raw []byte) []byte {
	var req Request
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
