// Package verifywails 用 Wails 的 WebView 窗口完成网站的反爬人机验证
// （当前针对 Cloudflare），把验证后的 Cookie 交回书源引擎。
//
// 为什么需要 CDP：Cloudflare 通过 managed challenge 之后下发的 cf_clearance
// 是 **HttpOnly** 的，页面脚本里的 document.cookie 读不到；而 Wails 没有暴露
// Cookie API（v3.0.0 的 Window 接口里没有任何 Cookie 方法）。唯一的官方口子
// 是 WebView2 的远程调试端口——开一个 CDP 连接就能读到浏览器内核里的全部
// Cookie，包括 HttpOnly 项（实测 Storage.getCookies 可读）。
package verifywails

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// cdp 是 Chrome DevTools Protocol 的最小实现：连一个目标、发一条命令、取回结果。
//
// 只用到三个方法：Storage.getCookies（读 HttpOnly Cookie）、
// Runtime.evaluate（判断验证页是否已通过）、以及 /json/version 取浏览器 UA。
type cdp struct {
	conn *websocket.Conn
	mu   sync.Mutex
	id   int
}

type cdpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// call 发一条 CDP 命令并等它的响应。
//
// CDP 的响应与事件共用同一条 WebSocket，所以必须按 id 过滤；
// 读操作全在 mu 下串行，避免多 goroutine 抢同一条连接把响应读乱。
func (c *cdp) call(ctx context.Context, method string, params any, out any) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.id++
	want := c.id
	msg := map[string]any{"id": want, "method": method}
	if params != nil {
		msg["params"] = params
	}
	payload, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	if err := c.conn.Write(ctx, websocket.MessageText, payload); err != nil {
		return err
	}
	for {
		_, data, err := c.conn.Read(ctx)
		if err != nil {
			return err
		}
		var env struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *cdpError       `json:"error"`
		}
		if json.Unmarshal(data, &env) != nil || env.ID != want {
			continue // 事件或其他命令的响应
		}
		if env.Error != nil {
			return fmt.Errorf("cdp %s: %s", method, env.Error.Message)
		}
		if out != nil && len(env.Result) > 0 {
			return json.Unmarshal(env.Result, out)
		}
		return nil
	}
}

func (c *cdp) close() {
	if c != nil && c.conn != nil {
		_ = c.conn.CloseNow()
	}
}

// cdpCookie 是 CDP 的 Cookie 结构（只留用得上的字段）。
type cdpCookie struct {
	Name     string  `json:"name"`
	Value    string  `json:"value"`
	Domain   string  `json:"domain"`
	Path     string  `json:"path"`
	HTTPOnly bool    `json:"httpOnly"`
	Secure   bool    `json:"secure"`
	Expires  float64 `json:"expires"` // Unix 秒，-1 表示会话 Cookie
}

// DialBrowser 连接浏览器级 CDP 端点，同时返回浏览器 UA。
//
// UA 必须一起取：cf_clearance 与 UA 绑定，Go 侧后续请求要换成同一个 UA，
// 否则验证过了仍然 403。
func DialBrowser(ctx context.Context, port int) (*cdp, string, error) {
	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	var version struct {
		WSURL     string `json:"webSocketDebuggerUrl"`
		UserAgent string `json:"User-Agent"`
	}
	if err := getJSON(ctx, base+"/json/version", &version); err != nil {
		return nil, "", fmt.Errorf("读取 CDP 版本信息失败: %w", err)
	}
	if version.WSURL == "" {
		return nil, "", fmt.Errorf("CDP 未返回 webSocketDebuggerUrl（端口 %d）", port)
	}
	conn, _, err := websocket.Dial(ctx, version.WSURL, nil)
	if err != nil {
		return nil, "", fmt.Errorf("连接 CDP 失败: %w", err)
	}
	return &cdp{conn: conn}, version.UserAgent, nil
}

// Cookies 读取浏览器内全部 Cookie（含 HttpOnly）。
func (c *cdp) Cookies(ctx context.Context) ([]cdpCookie, error) {
	var out struct {
		Cookies []cdpCookie `json:"cookies"`
	}
	if err := c.call(ctx, "Storage.getCookies", map[string]any{}, &out); err != nil {
		return nil, err
	}
	return out.Cookies, nil
}

// DomainCookie 拼出某域名可用的 Cookie 串。
//
// domain 传 eTLD+1（与引擎 CookieStore 的 key 一致），子域名的 Cookie 一并纳入，
// 这是 Cloudflare 的常见形态（cf_clearance 常挂在 .example.com 上）。
func DomainCookie(all []cdpCookie, domain string) string {
	if domain == "" {
		return ""
	}
	now := float64(time.Now().Unix())
	parts := make([]string, 0, len(all))
	for _, ck := range all {
		if ck.Name == "" {
			continue
		}
		d := strings.TrimPrefix(ck.Domain, ".")
		if d != domain && !strings.HasSuffix(d, "."+domain) {
			continue
		}
		// Expires <= 0 表示会话 Cookie（CDP 里 -1），只有明确过期才丢
		if ck.Expires > 0 && ck.Expires < now {
			continue
		}
		parts = append(parts, ck.Name+"="+ck.Value)
	}
	return strings.Join(parts, "; ")
}

// HasCookie 判断 Cookie 串里是否已有指定 key 且值非空。
func HasCookie(cookieStr, name string) bool {
	for _, part := range strings.Split(cookieStr, ";") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok && k == name && strings.TrimSpace(v) != "" {
			return true
		}
	}
	return false
}

// pageTarget 是 /json/list 里的一条目标（每个 WebView 窗口一条）。
type pageTarget struct {
	Type  string `json:"type"`
	URL   string `json:"url"`
	WSURL string `json:"webSocketDebuggerUrl"`
}

// PageEval 在与 host 匹配的窗口上执行 JS，返回表达式的结果字符串。
//
// 直连页面级 WebSocket，不走 Target.attachToTarget，少一层 sessionId 处理。
func PageEval(ctx context.Context, port int, host, expression string) (string, error) {
	var targets []pageTarget
	if err := getJSON(ctx, fmt.Sprintf("http://127.0.0.1:%d/json/list", port), &targets); err != nil {
		return "", err
	}
	for _, t := range targets {
		if t.Type != "page" || t.WSURL == "" {
			continue
		}
		if !strings.Contains(t.URL, host) {
			continue
		}
		conn, _, err := websocket.Dial(ctx, t.WSURL, nil)
		if err != nil {
			return "", err
		}
		page := &cdp{conn: conn}
		defer page.close()
		var res struct {
			Result struct {
				Type  string `json:"type"`
				Value string `json:"value"`
			} `json:"result"`
		}
		err = page.call(ctx, "Runtime.evaluate", map[string]any{
			"expression":    expression,
			"returnByValue": true,
			"awaitPromise":  false,
		}, &res)
		if err != nil {
			return "", err
		}
		return res.Result.Value, nil
	}
	return "", fmt.Errorf("没有找到匹配 %s 的页面目标", host)
}

// pickFreePort 找一个本机空闲端口给 WebView2 的调试端口用。
//
// 存在"选完到 WebView2 真正监听"之间的竞态，实务上窗口极小（同一进程内
// 几毫秒），且端口被占时 WebView2 只是不开调试口——验证功能降级为不可用，
// 不影响应用本身启动。
func pickFreePort() int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0
	}
	defer l.Close() //nolint:errcheck
	if addr, ok := l.Addr().(*net.TCPAddr); ok {
		return addr.Port
	}
	return 0
}

func getJSON(ctx context.Context, url string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	// 本机回环不能走系统代理：国内代理工具常把 127.0.0.1 也接管，
	// 一旦走代理这里会 502（与 Wails MCP 的 9099 同一个坑）。
	client := &http.Client{
		Timeout:   5 * time.Second,
		Transport: &http.Transport{Proxy: nil},
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close() //nolint:errcheck
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(out)
}
