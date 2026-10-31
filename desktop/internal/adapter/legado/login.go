package legado

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/legado/legado-go/pkg/js"
	legadomodel "github.com/legado/legado-go/pkg/model"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/urlx"

	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// Loginer 实现 port.SourceLoginer。
//
// 与 Kotlin 原版的对应关系：
//   - 登录方式判定 ↔ SourceLoginActivity.initView（loginUi 为空 → 网页，否则表单）
//   - RunLoginJS    ↔ BaseSource.login()（执行 loginUrl 里的 login 函数）
//   - ApplyCookie   ↔ BaseSource.putLoginHeader()（Cookie 写 CookieStore）
//
// 与原版不同的是**没有内置浏览器**：桌面端拿不到 WebView 的 HttpOnly Cookie
// （见 ARCHITECTURE.md「书源登录」一节的取舍说明），网页登录走「浏览器打开 +
// 粘贴 Cookie」，最终都落到同一个 CookieStore，对抓取链路的效果完全一致。
type Loginer struct {
	// UserAgent 保留给将来做登录页预探测用，目前不影响脚本执行。
	UserAgent string
}

// NewLoginer 创建书源登录执行器。
func NewLoginer(userAgent string) *Loginer { return &Loginer{UserAgent: userAgent} }

var _ port.SourceLoginer = (*Loginer)(nil)

// LoginKind 判定登录方式，并给出脚本正文或登录页地址。
func (l *Loginer) LoginKind(src *domain.BookSource) (string, string) {
	eng, err := toEngineSource(src)
	if err != nil {
		return port.LoginKindNone, ""
	}
	raw := strings.TrimSpace(eng.LoginUrl)
	if raw == "" {
		return port.LoginKindNone, ""
	}
	if js, ok := loginJS(raw); ok {
		return port.LoginKindJS, js
	}
	// 不是显式脚本时按地址形态判断：原版这里是「loginUi 为空就开网页」，
	// 但少数书源会同时给出 loginUi 和一个普通地址，那种情况下网页登录才有效。
	if looksLikeURL(raw) {
		return port.LoginKindPage, raw
	}
	// 既不是地址也没写 @js: 前缀：按原版 getLoginJs() 的行为当作裸脚本。
	return port.LoginKindJS, raw
}

// RunLoginJS 执行登录脚本。
//
// 脚本按原版约定**必须定义 login 函数**：书源里普遍写成
//
//	var info = source.getLoginInfoMap();
//	function login() { java.post(...) }
//
// 所以这里包一层调用，而不是直接执行脚本体——直接执行只会定义函数、什么都不做，
// 表现为「点登录毫无反应」。
func (l *Loginer) RunLoginJS(ctx context.Context, src *domain.BookSource, script string, opt port.LoginRunOptions) (port.LoginScriptResult, error) {
	if err := ctx.Err(); err != nil {
		return port.LoginScriptResult{}, err
	}
	eng, err := toEngineSource(src)
	if err != nil {
		return port.LoginScriptResult{}, err
	}
	script = strings.TrimSpace(script)
	if script == "" {
		return port.LoginScriptResult{}, fmt.Errorf("%w: 登录脚本为空", domain.ErrInvalidArgument)
	}

	var logs []string
	b := &js.Bindings{
		Source:  eng,
		BaseUrl: eng.BookSourceUrl,
		Result:  opt.Result,
		LoginInfo: func() map[string]string {
			return opt.Info
		},
		SetLoginHeader: func(headerJSON string) error {
			l.applyHeaderCookie(eng, headerJSON)
			if opt.OnHeader != nil {
				return opt.OnHeader(headerJSON)
			}
			return nil
		},
		LogHook: func(msg string) {
			// 日志是给用户看排错用的，留一段就够，不要被死循环脚本撑爆内存。
			if len(logs) < 100 {
				logs = append(logs, msg)
			}
		},
	}

	if opt.CallLogin {
		script = wrapLoginScript(script)
	}
	out, err := js.DefaultEngine().Eval(script, b)
	if err != nil {
		return port.LoginScriptResult{Logs: logs, Cookie: l.Cookie(src)}, err
	}
	return port.LoginScriptResult{
		Output: describeJSValue(out),
		Logs:   logs,
		Cookie: l.Cookie(src),
	}, nil
}

// Cookie 读取该书源域名下已保存的 Cookie。
func (l *Loginer) Cookie(src *domain.BookSource) string {
	if src == nil {
		return ""
	}
	return store.Default().GetCookie(src.URL)
}

// ApplyCookie 写入 Cookie（与已有值合并，同名 key 覆盖）。
func (l *Loginer) ApplyCookie(src *domain.BookSource, cookie string) {
	if src == nil || strings.TrimSpace(cookie) == "" {
		return
	}
	store.Default().ReplaceCookie(src.URL, cookie)
}

// ClearCookie 清除该书源域名下的 Cookie。
func (l *Loginer) ClearCookie(src *domain.BookSource) {
	if src == nil {
		return
	}
	store.Default().RemoveCookie(src.URL)
}

// Probe 探测登录态。
func (l *Loginer) Probe(ctx context.Context, src *domain.BookSource, probeURL string) (port.LoginProbe, error) {
	if err := ctx.Err(); err != nil {
		return port.LoginProbe{}, err
	}
	eng, err := toEngineSource(src)
	if err != nil {
		return port.LoginProbe{}, err
	}
	target := strings.TrimSpace(probeURL)
	if target == "" {
		target = probeURLFor(eng)
	}
	if target == "" {
		return port.LoginProbe{}, fmt.Errorf("%w: 书源没有可探测的地址（缺少 searchUrl / loginUrl / 书源地址）", domain.ErrInvalidArgument)
	}

	au := urlx.New(urlx.Options{
		Url:     target,
		Key:     eng.BookSourceUrl,
		BaseUrl: eng.BookSourceUrl,
		Source:  eng,
	})
	resp, err := au.GetStrResponse()
	if err != nil {
		return port.LoginProbe{}, fmt.Errorf("探测请求失败: %w", err)
	}

	out := port.LoginProbe{StatusCode: resp.StatusCode, URL: resp.URL}
	if checkJS := strings.TrimSpace(eng.LoginCheckJs); checkJS != "" {
		// loginCheckJs 的语义（对齐 WebBook.kt）：脚本**替换**响应体，
		// 返回值被拿去当新的 body 继续解析。也就是说：
		//   - 返回空 / 抛错        → 没替换，Cookie 有效
		//   - 返回与原文相同的正文 → 等于没替换，Cookie 有效
		//   - 返回另一段正文       → 被登录墙顶掉了
		// 早先按「非空即需登录」判定，脚本只要 `return result` 就会永远判成未登录。
		if v := strings.TrimSpace(au.EvalCheckJs(checkJS, resp)); v != "" && v != strings.TrimSpace(resp.Body) {
			out.NeedLogin = true
			out.Detail = "登录检测脚本替换了响应：" + headRunes(v, 120)
		} else {
			out.Detail = "登录检测脚本未命中，Cookie 有效"
		}
		return out, nil
	}

	// 没有检测脚本时只能靠关键词与状态码，结论仅供参考。
	if kw := loginWallKeyword(resp.Body); kw != "" {
		out.NeedLogin = true
		out.Detail = fmt.Sprintf("页面出现「%s」", kw)
		return out, nil
	}
	if resp.StatusCode == 401 || resp.StatusCode == 403 {
		out.NeedLogin = true
		out.Detail = fmt.Sprintf("HTTP %d", resp.StatusCode)
		return out, nil
	}
	out.Detail = fmt.Sprintf("未发现登录墙（HTTP %d）", resp.StatusCode)
	return out, nil
}

// applyHeaderCookie 从登录头 JSON 里取出 Cookie 写进 CookieStore。
func (l *Loginer) applyHeaderCookie(eng *legadomodel.BookSource, headerJSON string) {
	m, err := domain.ParseLoginHeader(headerJSON)
	if err != nil || len(m) == 0 {
		return
	}
	if c := domain.CookieFromLoginHeader(m); c != "" {
		store.Default().ReplaceCookie(eng.BookSourceUrl, c)
	}
}

// wrapLoginScript 把脚本体包成「定义 + 调用 login()」。
func wrapLoginScript(script string) string {
	return script + "\n;(function(){\n" +
		"  if (typeof login === 'function') { return login.apply(this); }\n" +
		"  throw new Error('Function login not implements!!!');\n" +
		"})()"
}

// loginJS 解析 loginUrl 里的脚本形态，返回脚本体。
func loginJS(raw string) (string, bool) {
	switch {
	case strings.HasPrefix(strings.ToLower(raw), "@js:"):
		return strings.TrimSpace(raw[4:]), true
	case strings.HasPrefix(strings.ToLower(raw), "<js>"):
		end := strings.LastIndex(raw, "<")
		if end <= 4 {
			return "", true
		}
		return strings.TrimSpace(raw[4:end]), true
	}
	return "", false
}

// looksLikeURL 判断一段 loginUrl 是不是页面地址。
func looksLikeURL(s string) bool {
	lower := strings.ToLower(s)
	switch {
	case strings.HasPrefix(lower, "http://"), strings.HasPrefix(lower, "https://"):
		return true
	case strings.HasPrefix(s, "/"), strings.HasPrefix(s, "./"), strings.HasPrefix(s, "../"):
		return true
	}
	return false
}

// probeURLFor 挑一个最能反映登录态的地址。
//
// 优先搜索页：需要登录的书源通常就是「搜索被登录墙拦住」；
// 其次是登录页（登录后一般会跳走）；最后退回站点首页。
//
// searchUrl 若是 JS 规则（@js:/<js>）就没法直接请求，跳过它——
// 早先没判断，探测请求会把整段脚本当地址发出去，必定失败。
func probeURLFor(src *legadomodel.BookSource) string {
	if s := strings.TrimSpace(src.SearchUrl); s != "" && !isJSRule(s) {
		return fillProbePlaceholders(s)
	}
	for _, u := range []string{src.LoginUrl, src.BookSourceUrl} {
		u = strings.TrimSpace(u)
		if u != "" && !isJSRule(u) {
			return fillProbePlaceholders(u)
		}
	}
	return strings.TrimSpace(src.BookSourceUrl)
}

// isJSRule 判断一段规则是不是脚本而不是地址。
func isJSRule(s string) bool {
	lower := strings.ToLower(strings.TrimSpace(s))
	return strings.HasPrefix(lower, "@js:") || strings.HasPrefix(lower, "<js>")
}

// fillProbePlaceholders 把地址里的模板变量换成具体值。
//
// 不做这一步，探测请求会带上 `?q={{key}}`，或者更糟：引擎把 key 当成
// baseUrl 填进去（`?q=http://站点`），得到一个和「登录态」无关的页面，
// 结论自然也不可信。
func fillProbePlaceholders(u string) string {
	if !strings.Contains(u, "{{") {
		return u
	}
	u = strings.ReplaceAll(u, "{{key}}", url.QueryEscape("测试"))
	u = strings.ReplaceAll(u, "{{page}}", "1")
	return u
}

// loginWallKeywords 是判断「页面要求登录」的兜底关键词。
var loginWallKeywords = []string{
	"请先登录", "请登录", "请登陆", "未登录", "登录后查看", "登录后阅读",
	"登录后继续", "login required", "please login", "please sign in",
}

// loginWallKeyword 返回命中的第一个登录墙关键词。
func loginWallKeyword(body string) string {
	// 只在头部找：正文里出现「请登录」的地方太多了（页脚、评论框），
	// 整篇扫一遍误报率极高。登录墙通常在标题/首屏。
	head := body
	if len(head) > 4000 {
		head = head[:4000]
	}
	lower := strings.ToLower(head)
	for _, kw := range loginWallKeywords {
		if strings.Contains(lower, strings.ToLower(kw)) {
			return kw
		}
	}
	return ""
}

// describeJSValue 把脚本返回值转成可展示的文本。
func describeJSValue(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	}
	if b, err := json.Marshal(v); err == nil {
		return string(b)
	}
	return fmt.Sprint(v)
}
