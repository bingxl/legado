//go:build android

package verifywails

import (
	"log/slog"

	"github.com/legado/core/port"
)

// Install 在安卓端暂不注册人机验证求解器。
//
// 原因：cf_clearance 是 HttpOnly，前端 document.cookie 读不到；而 Wails 没有
// 暴露 Android WebView 的 CookieManager，Go 侧也没有 CDP 这类口子。宿主不注册
// handler 时，引擎会把人机验证页当作普通响应原样返回——行为与改造前一致，
// 至少不会卡住请求。
//
// 后续要支持时，正确做法是在 Java 侧拿到 WailsBridge 持有的 WebView 实例，
// 用 CookieManager.getInstance().getCookie(url) 取 Cookie，再经 JNI 回传。
func Install(port.EventBus) {
	slog.Info("安卓端暂未实现人机验证窗口，Cloudflare 拦截将按普通错误处理")
}
