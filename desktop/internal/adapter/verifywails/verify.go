//go:build !android

package verifywails

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"

	lgnet "github.com/legado/legado-go/pkg/net"

	"github.com/legado/desktop/internal/port"
)

// 验证窗口的节奏参数。
const (
	// verifyTimeout 用户最多有多久完成验证。CF 的托管挑战通常几秒就过，
	// 留 3 分钟足够应付滑块/点选这类交互式挑战，超时则当作放弃。
	verifyTimeout = 3 * time.Minute
	// pollInterval 轮询 Cookie 的间隔。走本机 CDP，开销可以忽略。
	pollInterval = 600 * time.Millisecond
	// minDwell 至少等这么久才允许"页面已放行"的兜底判定：
	// 挑战页刚 load 完时它的 JS 还没跑起来，立刻判定会把挑战页当正文。
	minDwell = 5 * time.Second
)

var (
	portOnce  sync.Once
	debugPort int
)

// DebugPort 返回给 WebView2 用的远程调试端口（0 表示没拿到）。
//
// 由 platform_desktop.go 在拼 --additional-browser-args 时调用；进程内只选一次，
// 之后 CDP 客户端和 WebView2 用同一个值。
func DebugPort() int {
	portOnce.Do(func() {
		debugPort = pickFreePort()
		if debugPort == 0 {
			slog.Warn("无法分配 WebView 调试端口，站点人机验证将不可用")
		}
	})
	return debugPort
}

// Install 把验证求解器注册到书源引擎。
//
// 必须在 application.New 之后调用（要用 Window 管理器），但注册本身只是存一个
// 回调，求解时才取 application.Get()，所以放在启动流程里任何位置都安全。
func Install(bus port.EventBus) {
	lgnet.ChallengeHandler = func(c lgnet.Challenge) (lgnet.ChallengeResult, error) {
		return solve(c, bus)
	}
}

// skip 记一条日志并告诉引擎"这次没通过"。
func skip(reason string, args ...any) (lgnet.ChallengeResult, error) {
	slog.Info("人机验证未完成: "+reason, args...)
	return lgnet.ChallengeResult{Skip: true}, nil
}

func solve(c lgnet.Challenge, bus port.EventBus) (lgnet.ChallengeResult, error) {
	app := application.Get()
	if app == nil || app.Window == nil {
		return skip("应用尚未就绪")
	}
	cdpPort := DebugPort()
	if cdpPort == 0 {
		return skip("WebView 调试端口不可用")
	}
	host := ""
	if u, err := url.Parse(c.URL); err == nil {
		host = u.Hostname()
	}

	ctx, cancel := context.WithTimeout(context.Background(), verifyTimeout)
	defer cancel()

	conn, ua, err := DialBrowser(ctx, cdpPort)
	if err != nil {
		// 端口没起来最常见的原因是用户用 LEGADO_WEBVIEW_ARGS 覆盖了默认参数
		return skip("连接浏览器内核失败: " + err.Error())
	}
	defer conn.close()

	// 先用现成的：WebView2 的 profile 是持久的，用户上次验证过的 cf_clearance
	// 可能还在。这种情况不必再弹窗——常见于"Go 侧 UA 没跟上导致被拒，
	// 但浏览器里凭证明明有效"，以及重启后重新验证。
	if cookies, err := conn.Cookies(ctx); err == nil {
		if all := DomainCookie(cookies, c.Domain); HasCookie(all, "cf_clearance") {
			slog.Info("浏览器已有有效验证凭证，直接复用", "domain", c.Domain)
			return lgnet.ChallengeResult{Cookie: all, UserAgent: ua}, nil
		}
	}

	title := "完成人机验证"
	if c.Domain != "" {
		title += " · " + c.Domain
	}
	w := app.Window.NewWithOptions(application.WebviewWindowOptions{
		Name:             "verify-" + strconv.FormatInt(time.Now().UnixNano(), 36),
		Title:            title,
		URL:              c.URL,
		Width:            980,
		Height:           760,
		AlwaysOnTop:      true,
		BackgroundColour: application.NewRGB(255, 255, 255),
	})
	if w == nil {
		return skip("创建验证窗口失败")
	}
	var closed atomic.Bool
	w.OnWindowEvent(events.Common.WindowClosing, func(*application.WindowEvent) { closed.Store(true) })
	defer w.Close()

	// 前端据此提示"验证完成后阅读会自动继续"，避免用户以为卡死。
	emit(bus, port.EventVerifyRequest, map[string]any{
		"domain": c.Domain, "url": c.URL, "title": title,
	})
	defer func() {
		emit(bus, port.EventVerifyDone, map[string]any{"domain": c.Domain})
	}()

	started := time.Now()
	for {
		select {
		case <-ctx.Done():
			return skip("等待验证超时", "domain", c.Domain)
		default:
		}
		time.Sleep(pollInterval)
		if closed.Load() {
			return skip("用户关闭了验证窗口", "domain", c.Domain)
		}

		cookies, err := conn.Cookies(ctx)
		if err != nil {
			continue // 挑战过程中页面在跳转，偶发读失败属正常
		}
		all := DomainCookie(cookies, c.Domain)
		// 首选 cf_clearance：拿到它之后 Go 侧的请求就能长期复用
		if HasCookie(all, "cf_clearance") {
			slog.Info("人机验证通过", "domain", c.Domain, "cookie_len", len(all))
			return lgnet.ChallengeResult{Cookie: all, UserAgent: ua}, nil
		}
		if time.Since(started) < minDwell {
			continue
		}
		// 兜底：站点不用 cf_clearance（自建验证、或只有 __cf_bm）时，
		// 看页面是否已经放行；放行就把它渲染出来的 HTML 当响应交给引擎。
		if !pagePassed(ctx, cdpPort, host) {
			continue
		}
		html, err := PageEval(ctx, cdpPort, host, "document.documentElement.outerHTML")
		if err != nil || html == "" {
			continue
		}
		slog.Info("人机验证通过（未拿到 cf_clearance，改用渲染结果）", "domain", c.Domain)
		return lgnet.ChallengeResult{Cookie: all, Body: html, UserAgent: ua}, nil
	}
}

// pagePassedJS 判断验证页是否已经放行。
//
// 挑战页的特征比较杂：托管挑战挂 window._cf_chl_opt，交互式挑战是
// #challenge-form / #challenge-running，还有的直接换标题。多看几个信号，
// 少一个就很容易把"还在验证"误判成"已通过"。
const pagePassedJS = `(function () {
  var t = document.title || '';
  var challenged = !!window._cf_chl_opt
    || /Just a moment|Attention Required|Verifying you are human|请稍候|正在验证|安全检查/i.test(t)
    || !!document.querySelector('#challenge-form,#challenge-running,#cf-please-wait,.cf-browser-verification');
  return JSON.stringify({ready: document.readyState === 'complete', challenged: challenged});
})()`

func pagePassed(ctx context.Context, cdpPort int, host string) bool {
	raw, err := PageEval(ctx, cdpPort, host, pagePassedJS)
	if err != nil {
		return false
	}
	var st struct {
		Ready      bool `json:"ready"`
		Challenged bool `json:"challenged"`
	}
	if json.Unmarshal([]byte(strings.TrimSpace(raw)), &st) != nil {
		return false
	}
	return st.Ready && !st.Challenged
}

func emit(bus port.EventBus, name string, payload map[string]any) {
	if bus == nil {
		return
	}
	_ = bus.Emit(context.Background(), name, payload)
}
