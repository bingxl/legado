package net

import (
	"strconv"
	"strings"
	"sync"

	"github.com/legado/legado-go/pkg/debug"
	"github.com/legado/legado-go/pkg/store"
	"github.com/legado/legado-go/pkg/util"
)

// 反爬人机验证（当前针对 Cloudflare）的处理契约。
//
// 引擎自身无法"破解"验证：Cloudflare 的 managed challenge 需要真实浏览器执行
// JS、采集指纹并产出 cf_clearance，而这个 Cookie 是 **HttpOnly** 的——页面脚本
// 读不到，只能由宿主从浏览器内核里取。
//
// 原版 legado 的做法同样是"交给浏览器、用户点一下、再复用凭证"：
//   - JsExtensions.startBrowserAwait → SourceVerificationHelp → WebViewActivity
//   - WebView 每次 onPageFinished 都把 CookieManager 的 Cookie 写回 CookieStore
//   - 验证通过后 AnalyzeUrl 重新请求同一地址（此时带上 cf_clearance）
//
// 因此这里只定义「检测 → 交给宿主 → 带新凭证重试」的骨架，浏览器由宿主提供：
//   - 桌面端：新建 Wails 窗口加载验证页，用 CDP 读回 cf_clearance 与 UA
//   - 安卓端：暂未实现；宿主不注册 Handler 时引擎按普通响应原样返回
//
// 只在 net 层做检测的好处是：搜索、详情、目录、正文、图片、音频全都走同一个
// HTTP 出口，验证一次就对整条链路生效，不需要改任何一个书源。

// Challenge 描述一次被反爬拦截的请求。宿主可据此提示用户、决定窗口标题。
type Challenge struct {
	// URL 被拦截的原始地址
	URL string
	// Domain 归属域名（eTLD+1），与 CookieStore 的 key 一致
	Domain string
	// StatusCode 上游返回的状态码（挑战页通常是 403/503）
	StatusCode int
	// Reason 判定依据，便于日志与给用户看的提示文案
	Reason string
}

// ChallengeResult 是宿主完成（或放弃）人工验证后回填的结果。
type ChallengeResult struct {
	// Cookie 浏览器的 Cookie 串（形如 "cf_clearance=xxx; __cf_bm=yyy"）。
	// 含 HttpOnly 项也没关系，宿主从内核取到的就是完整集合。
	Cookie string
	// UserAgent 完成验证所用浏览器的 UA。cf_clearance 与 UA 绑定，
	// 后续请求必须换成同一个 UA，否则 Cookie 仍会被判定无效。
	UserAgent string
	// Body 宿主直接拿到的页面内容（浏览器里 document 的 HTML）。
	// 仅作为兜底：宿主拿不到 Cookie 但页面确实渲染成功时，直接当响应体用。
	Body string
	// Skip 用户放弃或宿主主动取消，调用方应原样返回被拦截的响应
	Skip bool
}

// ChallengeHandler 由宿主注册。为 nil 表示当前环境不支持人工验证，
// 引擎不会因为反爬而阻塞——直接返回被拦截的响应。
var ChallengeHandler func(c Challenge) (ChallengeResult, error)

// challengeScanLimit 只扫正文前 64 KiB。
//
// 挑战页只有几 KB，而正常响应可能是几十 MB 的正文或图片；不设上限会让每次
// 请求都做一次全量字符串匹配。
const challengeScanLimit = 64 << 10

// cfChallengeMarkers 是 Cloudflare 挑战页的正文特征。
//
// 只保留"出现即可判定"的强特征：像 "请稍候" 这类通用文案会误伤正常页面，
// 不放进来。真正可靠的信号是响应头 cf-mitigated（见 IsCloudflareChallenge）。
var cfChallengeMarkers = []string{
	"window._cf_chl_opt",
	"/cdn-cgi/challenge-platform/",
	"_cf_chl_",
	"cf-browser-verification",
	"cf-challenge",
	"Just a moment...",
	"Attention Required! | Cloudflare",
	"Verifying you are human",
	"Enable JavaScript and cookies to continue",
	"正在验证您是否是真人",
}

// IsCloudflareChallenge 判定响应是否为人机验证页，并给出判定依据。
//
// 判定优先级：
//  1. 响应头 cf-mitigated: challenge —— Cloudflare 官方文档给出的唯一可靠信号
//     （https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/）
//  2. 拒绝类状态码 + 正文命中挑战页特征
//
// 之所以不只看 Server: cloudflare：几乎所有 CF 站点都带这个头，正常工作也带，
// 但 Cloudflare 官方明确说明它**不能**用来判定是否为验证页。
func IsCloudflareChallenge(status int, headers map[string]string, body string) (bool, string) {
	if v := headerValue(headers, "cf-mitigated"); v != "" {
		if strings.EqualFold(strings.TrimSpace(v), "challenge") {
			return true, "cf-mitigated: challenge"
		}
	}
	// 挑战页只出现在拒绝类状态码上；2xx 正常响应即便正文含关键字也不是拦截
	// （例如书源页脚恰好写了 "Just a moment..."）。
	switch status {
	case 403, 429, 503:
	default:
		return false, ""
	}
	head := body
	if len(head) > challengeScanLimit {
		head = head[:challengeScanLimit]
	}
	for _, m := range cfChallengeMarkers {
		if strings.Contains(head, m) {
			return true, "status=" + strconv.Itoa(status) + " marker=" + m
		}
	}
	return false, ""
}

// headerValue 忽略大小写取响应头。
//
// net.Response.Headers 在 Go 侧已做规范化，但检测函数也接受宿主/测试手写的
// map，所以这里不能假设 key 一定是 CanonicalMIMEHeaderKey 形式。
func headerValue(headers map[string]string, key string) string {
	if headers == nil {
		return ""
	}
	if v, ok := headers[key]; ok {
		return v
	}
	for k, v := range headers {
		if strings.EqualFold(k, key) {
			return v
		}
	}
	return ""
}

var (
	uaOverrideMu sync.RWMutex
	uaOverrides  = map[string]string{}
	domainLocks  sync.Map // domain -> *sync.Mutex
)

// SetUserAgentOverride 记录某域名后续应使用的 UA。
//
// cf_clearance 与 UA 绑定：浏览器里通过验证用的是 WebView 的 UA，之后用 Go
// 直接发请求必须换成同一个 UA，否则 Cloudflare 仍然判定 Cookie 无效（表现为
// 验证窗口明明通过了，正文还是 403）。
func SetUserAgentOverride(domain, ua string) {
	if domain == "" || ua == "" {
		return
	}
	uaOverrideMu.Lock()
	uaOverrides[domain] = ua
	uaOverrideMu.Unlock()
}

// UserAgentOverride 取某域名的 UA 覆盖值，没有覆盖时返回空串。
func UserAgentOverride(domain string) string {
	uaOverrideMu.RLock()
	defer uaOverrideMu.RUnlock()
	return uaOverrides[domain]
}

// ClearUserAgentOverride 清除某域名的 UA 覆盖。
//
// 书源被修改、登录态被清空（cookie.removeCookie）时应当一并清掉：验证凭证
// 已经失效，继续沿用浏览器 UA 会让书源自己配置的 UA 永久失效。
func ClearUserAgentOverride(domain string) {
	uaOverrideMu.Lock()
	delete(uaOverrides, domain)
	uaOverrideMu.Unlock()
}

// ResetChallengeState 清空全部验证状态（UA 覆盖 + 域名串行锁）。
// 主要给测试和"清空 Cookie"这类维护操作使用。
func ResetChallengeState() {
	uaOverrideMu.Lock()
	uaOverrides = map[string]string{}
	uaOverrideMu.Unlock()
	domainLocks = sync.Map{}
}

// ApplyChallengeResult 把宿主的验证结果落到引擎状态里。
//
// 用 ReplaceCookie 而不是 SetCookie：验证只新增/刷新 cf_clearance，原有登录态
// Cookie 必须保留——整份覆盖会把用户已经登录的会话踢掉。
func ApplyChallengeResult(u string, r ChallengeResult) {
	if u == "" {
		return
	}
	if r.Cookie != "" {
		store.Default().ReplaceCookie(u, r.Cookie)
	}
	if r.UserAgent != "" {
		SetUserAgentOverride(util.GetSubDomain(u), r.UserAgent)
	}
}

// RunChallenge 请求宿主完成人工验证，并把结果落到 CookieStore / UA 覆盖表。
//
// 返回 ok=false 表示宿主不支持或用户放弃，调用方应原样返回被拦截的响应。
// 同一域名内串行：并发抓章节时不能让用户同时面对 N 个验证窗口。
func RunChallenge(c Challenge) (ChallengeResult, bool) {
	h := ChallengeHandler
	if h == nil {
		return ChallengeResult{}, false
	}
	if c.Domain == "" {
		c.Domain = util.GetSubDomain(c.URL)
	}
	v, _ := domainLocks.LoadOrStore(c.Domain, &sync.Mutex{})
	mu := v.(*sync.Mutex)
	mu.Lock()
	defer mu.Unlock()

	debug.Logf("≡检测到人机验证（%s），等待宿主处理：%s", c.Reason, c.URL)
	res, err := h(c)
	if err != nil {
		debug.Errorf("人机验证失败 %s: %v", c.URL, err)
		return ChallengeResult{}, false
	}
	if res.Skip {
		debug.Logf("≡跳过人机验证（用户取消或环境不支持）：%s", c.URL)
		return ChallengeResult{}, false
	}
	ApplyChallengeResult(c.URL, res)
	return res, true
}
