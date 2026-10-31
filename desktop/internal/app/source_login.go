package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"github.com/legado/desktop/internal/app/dto"
	"github.com/legado/desktop/internal/domain"
	"github.com/legado/desktop/internal/port"
)

// SourceLoginService 负责书源（含漫画源）的登录。
//
// 职责边界：
//   - 它只处理「登录这件事」——判定登录方式、跑脚本、存取 Cookie 与登录头、探测登录态。
//   - 真正的 HTTP 与 JS 执行在 port.SourceLoginer 里；Cookie 落盘由引擎的 CookieStore 负责。
//
// 与原版 Android 的一处差异：没有内置浏览器。桌面端读不到 WebView 的
// HttpOnly Cookie（详见 ARCHITECTURE.md），所以「网页登录」这条路是
// 「用系统浏览器打开登录页 → 复制 Cookie 粘贴回来」。最终都落到同一个
// CookieStore，对抓取链路来说是等价的。
type SourceLoginService struct {
	sources port.BookSourceRepository
	logins  port.SourceLoginRepository
	engine  port.SourceLoginer
}

// SourceLoginDeps 聚合登录服务的依赖。
type SourceLoginDeps struct {
	Sources port.BookSourceRepository
	Logins  port.SourceLoginRepository
	Engine  port.SourceLoginer
}

// NewSourceLoginService 构造书源登录服务。
func NewSourceLoginService(d SourceLoginDeps) *SourceLoginService {
	return &SourceLoginService{sources: d.Sources, logins: d.Logins, engine: d.Engine}
}

// sourceLoginMeta 是从书源原始 JSON 里挑出来的登录相关字段。
type sourceLoginMeta struct {
	LoginURL     string `json:"loginUrl"`
	LoginUI      string `json:"loginUi"`
	LoginCheckJS string `json:"loginCheckJs"`
	Type         int    `json:"bookSourceType"`
}

// readSourceLoginMeta 解析书源原始 JSON。
//
// 解析失败不报错：管理字段（名称/地址）仍然可用，界面至少能打开，
// 顶多是「没有声明登录方式」，用户还能手动粘贴 Cookie。
func readSourceLoginMeta(src *domain.BookSource) sourceLoginMeta {
	var m sourceLoginMeta
	if src == nil || strings.TrimSpace(src.Raw) == "" {
		return m
	}
	_ = json.Unmarshal([]byte(src.Raw), &m)
	return m
}

// Profile 读取登录面板需要的全部信息。
func (s *SourceLoginService) Profile(ctx context.Context, sourceID int64) (dto.SourceLoginView, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return dto.SourceLoginView{}, err
	}
	meta := readSourceLoginMeta(src)

	kind, payload := s.engine.LoginKind(src)
	view := dto.SourceLoginView{
		SourceID:   src.ID,
		SourceName: src.Name,
		SourceURL:  src.URL,
		SourceType: meta.Type,
		Kind:       kind,
		Fields:     parseLoginFields(meta.LoginUI),
		CheckJS:    strings.TrimSpace(meta.LoginCheckJS) != "",
	}
	if kind == port.LoginKindPage {
		view.LoginURL = absoluteURL(src.URL, payload)
	}

	// 已保存的登录信息：没有不是错误，界面显示「未登录」即可。
	saved, err := s.logins.Get(ctx, src.URL)
	if err == nil {
		view.Info = saved.Form
		view.Header = saved.Header
		if !saved.UpdatedAt.IsZero() {
			t := saved.UpdatedAt
			view.UpdatedAt = &t
		}
	} else if !errors.Is(err, domain.ErrNotFound) {
		return dto.SourceLoginView{}, err
	}

	cookie := s.engine.Cookie(src)
	view.HasCookie = strings.TrimSpace(cookie) != ""
	view.CookieMask = domain.MaskCookie(cookie)
	return view, nil
}

// Login 执行登录。
//
// 三种登录方式：
//   - js   ：先落表单（失败重试不用重填），再执行脚本里的 login()；
//   - page ：返回登录页地址，前端用浏览器打开，用户粘 Cookie 回来；
//   - none ：提示只能粘贴 Cookie。
//
// 脚本执行失败**不返回 error**：用户需要看到脚本日志，
// 而 error 只能带一句话。只有参数问题（书源不存在、ID 为空）才抛错。
func (s *SourceLoginService) Login(ctx context.Context, sourceID int64, form map[string]string) (dto.LoginResult, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return dto.LoginResult{}, err
	}
	kind, payload := s.engine.LoginKind(src)

	switch kind {
	case port.LoginKindNone:
		return dto.LoginResult{
			Message: "该书源没有声明登录地址，请直接粘贴浏览器里的 Cookie",
		}, nil
	case port.LoginKindPage:
		return dto.LoginResult{
			OpenURL: absoluteURL(src.URL, payload),
			Message: "请在浏览器完成登录，然后把 Cookie 粘贴到下面的输入框",
		}, nil
	}

	if form == nil {
		form = map[string]string{}
	}
	// 先存表单：登一次失败再改密码是常态，每次都要重敲账号太反人类。
	s.saveForm(ctx, src.URL, form)

	before := s.engine.Cookie(src)
	res, err := s.engine.RunLoginJS(ctx, src, payload, port.LoginRunOptions{
		Info:      form,
		CallLogin: true,
		OnHeader: func(headerJSON string) error {
			return s.persistHeader(ctx, src.URL, headerJSON)
		},
	})
	if err != nil {
		return dto.LoginResult{
			Message: "登录脚本执行失败：" + err.Error(),
			Logs:    res.Logs,
		}, nil
	}

	out := dto.LoginResult{
		Logs:       res.Logs,
		Output:     res.Output,
		CookieMask: domain.MaskCookie(res.Cookie),
		LoggedIn:   strings.TrimSpace(res.Cookie) != "",
	}
	switch {
	case out.LoggedIn:
		out.OK = true
		out.Message = "登录成功，登录信息已保存"
		if before != "" && before == res.Cookie {
			// 脚本跑完了但 Cookie 与登录前一样：多半是脚本没真的发请求。
			out.Message = "脚本执行完成，但登录态没有变化，请确认脚本是否真的发起了登录请求"
			out.OK = false
		}
	case strings.TrimSpace(res.Output) != "":
		out.Message = "脚本执行完成，但没有拿到 Cookie：" + res.Output
	default:
		out.Message = "脚本执行完成，但没有拿到 Cookie：请检查账号密码，或该站点是否需要验证码"
	}
	return out, nil
}

// RunAction 执行 loginUi 里自定义按钮的动作。
//
// 与登录按钮的区别：按钮脚本是**动作片段**，原版把它拼在登录脚本后面执行
// （`loginJS + buttonFunctionJS`），并且能通过 `result` 读到表单值。
// 这里必须显式关掉 CallLogin，否则会把整个登录流程又跑一遍。
func (s *SourceLoginService) RunAction(ctx context.Context, sourceID int64, action string, form map[string]string) (dto.LoginResult, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return dto.LoginResult{}, err
	}
	action = strings.TrimSpace(action)
	if action == "" {
		return dto.LoginResult{Message: "该按钮没有配置动作"}, nil
	}
	if isURL(action) {
		return dto.LoginResult{OpenURL: absoluteURL(src.URL, action)}, nil
	}

	kind, loginJS := s.engine.LoginKind(src)
	script := action
	if kind == port.LoginKindJS && strings.TrimSpace(loginJS) != "" {
		script = loginJS + "\n;\n" + action
	}
	if form == nil {
		form = map[string]string{}
	}
	res, err := s.engine.RunLoginJS(ctx, src, script, port.LoginRunOptions{
		Info:   form,
		Result: form,
		OnHeader: func(headerJSON string) error {
			return s.persistHeader(ctx, src.URL, headerJSON)
		},
	})
	if err != nil {
		return dto.LoginResult{Message: "按钮脚本执行失败：" + err.Error(), Logs: res.Logs}, nil
	}
	out := dto.LoginResult{
		OK:         true,
		Logs:       res.Logs,
		Output:     res.Output,
		CookieMask: domain.MaskCookie(res.Cookie),
		LoggedIn:   strings.TrimSpace(res.Cookie) != "",
		Message:    "按钮脚本执行完成",
	}
	return out, nil
}

// SaveHeader 保存手动粘贴的登录头（含 Cookie）。
//
// 这条路覆盖三类场景：网页登录后复制 Cookie、书源自带 token 头、
// 以及「脚本登录成功了但我想换一份更完整的头」。
func (s *SourceLoginService) SaveHeader(ctx context.Context, sourceID int64, header string) (dto.LoginResult, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return dto.LoginResult{}, err
	}
	m, err := domain.ParseLoginHeader(header)
	if err != nil {
		return dto.LoginResult{}, err
	}
	cookie := domain.CookieFromLoginHeader(m)
	if cookie == "" {
		return dto.LoginResult{}, fmt.Errorf("%w: 没有找到 Cookie，请粘贴包含 Cookie 的内容", domain.ErrInvalidArgument)
	}

	// 引擎按域名合并写入：只改某一项时不会把之前的登录态清掉。
	s.engine.ApplyCookie(src, cookie)
	normalized := domain.LoginHeaderJSON(m)
	if err := s.persistHeader(ctx, src.URL, normalized); err != nil {
		return dto.LoginResult{}, err
	}

	merged := s.engine.Cookie(src)
	return dto.LoginResult{
		OK:         true,
		LoggedIn:   true,
		Message:    "登录信息已保存",
		CookieMask: domain.MaskCookie(merged),
	}, nil
}

// Header 返回保存的登录请求头原文（供「查看/复制」）。
func (s *SourceLoginService) Header(ctx context.Context, sourceID int64) (string, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return "", err
	}
	saved, err := s.logins.Get(ctx, src.URL)
	if errors.Is(err, domain.ErrNotFound) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return saved.Header, nil
}

// Clear 清除登录。
//
// withForm=false 只清登录态（Cookie + 登录头），保留账号密码，方便换个号继续；
// withForm=true 连表单一起删。
func (s *SourceLoginService) Clear(ctx context.Context, sourceID int64, withForm bool) error {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return err
	}
	s.engine.ClearCookie(src)

	if withForm {
		return s.logins.Delete(ctx, src.URL)
	}
	// 保留表单值，只把登录头清空。
	saved, err := s.logins.Get(ctx, src.URL)
	if errors.Is(err, domain.ErrNotFound) {
		return nil
	}
	if err != nil {
		return err
	}
	if !saved.HasForm() {
		// 只剩一个空的登录头记录，直接删掉，别留垃圾行。
		return s.logins.Delete(ctx, src.URL)
	}
	saved.Header = ""
	return s.logins.Save(ctx, saved)
}

// Check 探测当前登录态。
func (s *SourceLoginService) Check(ctx context.Context, sourceID int64, probeURL string) (dto.LoginProbeView, error) {
	src, err := s.source(ctx, sourceID)
	if err != nil {
		return dto.LoginProbeView{}, err
	}
	probe, err := s.engine.Probe(ctx, src, probeURL)
	if err != nil {
		return dto.LoginProbeView{}, err
	}
	return dto.LoginProbeView{
		NeedLogin:  probe.NeedLogin,
		Detail:     probe.Detail,
		StatusCode: probe.StatusCode,
		URL:        probe.URL,
	}, nil
}

// ── 内部辅助 ────────────────────────────────────────────────

func (s *SourceLoginService) source(ctx context.Context, sourceID int64) (*domain.BookSource, error) {
	if sourceID <= 0 {
		return nil, fmt.Errorf("%w: 缺少书源 ID", domain.ErrInvalidArgument)
	}
	src, err := s.sources.Get(ctx, sourceID)
	if err != nil {
		return nil, err
	}
	if src == nil {
		return nil, fmt.Errorf("%w: 书源不存在", domain.ErrNotFound)
	}
	return src, nil
}

// saveForm 只更新表单值，保留已有的登录头。
func (s *SourceLoginService) saveForm(ctx context.Context, sourceURL string, form map[string]string) {
	saved, err := s.logins.Get(ctx, sourceURL)
	if err != nil && !errors.Is(err, domain.ErrNotFound) {
		return
	}
	saved.SourceURL = sourceURL
	saved.Form = form
	_ = s.logins.Save(ctx, saved)
}

// persistHeader 保存登录头。失败不影响登录本身（Cookie 已经在 CookieStore 里）。
func (s *SourceLoginService) persistHeader(ctx context.Context, sourceURL, headerJSON string) error {
	if strings.TrimSpace(headerJSON) == "" {
		return nil
	}
	saved, err := s.logins.Get(ctx, sourceURL)
	if err != nil && !errors.Is(err, domain.ErrNotFound) {
		return err
	}
	saved.SourceURL = sourceURL
	saved.Header = headerJSON
	return s.logins.Save(ctx, saved)
}

// parseLoginFields 解析 loginUi（对齐原版 RowUi）。
//
// loginUi 的两种存法都要认：JSON 数组，以及被转义成字符串的 JSON 数组
// （老版本导入器会把对象写成字符串）。
func parseLoginFields(raw string) []dto.LoginFieldView {
	s := strings.TrimSpace(raw)
	if s == "" || s == "null" {
		return nil
	}
	if strings.HasPrefix(s, `"`) {
		var inner string
		if err := json.Unmarshal([]byte(s), &inner); err == nil {
			s = strings.TrimSpace(inner)
		}
	}
	var rows []struct {
		Name   string `json:"name"`
		Type   string `json:"type"`
		Action string `json:"action"`
	}
	if err := json.Unmarshal([]byte(s), &rows); err != nil {
		return nil
	}
	out := make([]dto.LoginFieldView, 0, len(rows))
	for _, r := range rows {
		name := strings.TrimSpace(r.Name)
		typ := strings.ToLower(strings.TrimSpace(r.Type))
		if typ == "" {
			typ = "text"
		}
		if typ != "text" && typ != "password" && typ != "button" {
			continue // 未知类型直接忽略，别把界面撑成一堆空行
		}
		if name == "" {
			continue
		}
		out = append(out, dto.LoginFieldView{Name: name, Type: typ, Action: r.Action})
	}
	return out
}

// isURL 判断按钮动作是地址而不是脚本。
func isURL(s string) bool {
	lower := strings.ToLower(strings.TrimSpace(s))
	return strings.HasPrefix(lower, "http://") ||
		strings.HasPrefix(lower, "https://") ||
		strings.HasPrefix(lower, "/") ||
		strings.HasPrefix(lower, "./") ||
		strings.HasPrefix(lower, "../")
}

// absoluteURL 把书源里的相对地址补成绝对地址。
//
// 补不出来就原样返回：前端拿到的可能是「没法打开的地址」，
// 但比给一个空串（用户以为按钮坏了）要好——至少能看出书源写的是什么。
func absoluteURL(base, ref string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return ""
	}
	b, err := url.Parse(strings.TrimSpace(base))
	if err != nil || b.Scheme == "" {
		return ref
	}
	r, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return b.ResolveReference(r).String()
}
