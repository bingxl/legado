package port

import (
	"context"

	"github.com/legado/desktop/internal/domain"
)

// 书源登录方式。
//
// 三者的判定与 Legado 原版一致，只依据书源自身的字段（不联网）：
//   - loginUrl 为空                      → 只能手动粘贴 Cookie
//   - loginUi 非空，或 loginUrl 是 @js:/<js> → 表单 + 脚本登录
//   - 其余（http/https/相对地址）         → 网页登录
const (
	LoginKindNone = "none" // 没有声明登录方式
	LoginKindJS   = "js"   // 登录框 + JS
	LoginKindPage = "page" // 网页登录
)

// LoginScriptResult 是一次登录脚本执行的结果。
//
// Logs 收集 java.log/java.toast 的输出：书源脚本失败时往往只在 log 里写明原因
// （「账号或密码错误」），不回显就只能给用户一句「登录失败」。
type LoginScriptResult struct {
	Output string   // 脚本返回值（对象/数组按 JSON 序列化）
	Logs   []string // 脚本日志
	Cookie string   // 执行完该书源域名下的 Cookie（用于判断是否拿到登录态）
}

// LoginProbe 是登录态探测结果。
//
// 判定依据与 Legado 的 loginCheckJs 语义一致：脚本返回非空字符串
// 说明响应被「登录墙」替换了，即当前 Cookie 不可用。
type LoginProbe struct {
	NeedLogin  bool   // 是否需要登录
	Detail     string // 判定依据：脚本返回值 / 命中的关键词 / 状态码
	StatusCode int    // 探测请求的 HTTP 状态码
	URL        string // 实际请求地址（重定向后）
}

// LoginRunOptions 是一次登录脚本执行的上下文。
type LoginRunOptions struct {
	// Info 是登录框里用户填的值（键名 = loginUi 的 name）。
	Info map[string]string
	// Result 作为 JS 里的 result 变量。
	// loginUi 的按钮脚本按原版约定从 result 里取表单值（`result['账号']`）。
	Result map[string]string
	// OnHeader 在脚本调用 source.putLoginHeader 时回调，供上层持久化。
	// 为空时实现只把其中的 Cookie 写进 CookieStore。
	OnHeader func(headerJSON string) error
	// CallLogin 为 true 时按原版约定，脚本执行完再调用其中定义的 login()。
	// 登录按钮要置 true；loginUi 里自定义按钮的脚本本身就是动作片段，必须为 false，
	// 否则会连带把登录流程再跑一遍。
	CallLogin bool
}

// SourceLoginer 提供书源登录所需的能力。
//
// Cookie 的作用域与引擎一致：按书源地址的二级域名存取，
// 写进去之后书源抓取、图片下载都会自动带上（引擎的 HTTP 客户端统一注入）。
type SourceLoginer interface {
	// LoginKind 判定登录方式；第二个返回值是脚本正文或登录页地址。
	LoginKind(src *domain.BookSource) (kind string, payload string)
	// RunLoginJS 执行一段登录脚本（loginUrl 的 JS 或 loginUi 按钮的 action）。
	// info 是登录框里用户填的值，脚本里用 source.getLoginInfoMap() 取。
	RunLoginJS(ctx context.Context, src *domain.BookSource, js string, opt LoginRunOptions) (LoginScriptResult, error)
	// Cookie 读取该书源域名下已保存的 Cookie。
	Cookie(src *domain.BookSource) string
	// ApplyCookie 写入 Cookie（与已有值合并，同名 key 覆盖）。
	ApplyCookie(src *domain.BookSource, cookie string)
	// ClearCookie 清除该书源域名下的 Cookie。
	ClearCookie(src *domain.BookSource)
	// Probe 探测登录态；probeURL 为空时按书源字段自动选择。
	Probe(ctx context.Context, src *domain.BookSource, probeURL string) (LoginProbe, error)
}
