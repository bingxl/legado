# 多端从浏览器内核读取 HttpOnly Cookie —— 实现方案

> 前置：`CF-BYPASS-SURVEY.md`（为什么必须走真人浏览器）、`WAILS-FORK-COOKIE.md`（Windows 补丁细节）。
> 本文回答「三端 API 完全不同，怎么收敛成一份代码」。

---

## 0. 一句话方案

**平台差异只发生在「读 cookie」这一个动作上，其余全部共用。**

现有 `verifywails.solve()` 其实已经只依赖三个原语：

1. 读内核里某域名的全部 cookie
2. 取浏览器 UA
3. 拼成 `"a=1; b=2"` 交给引擎

把它抽成一个 3 方法接口，三端各实现一次，`solve()` 的窗口管理、轮询、事件、超时、兜底全部不变。

```
Windows WebView2 ──┐
Android  WebView ──┼──→ session{Cookies, UserAgent, Close} ──→ ChallengeResult ──→ CookieStore
Linux  WebKitGTK ──┘
```

---

## 1. 统一接口

新增 `desktop/internal/adapter/verifywails/session.go`：

```go
package verifywails

import "context"

// session 是一次"验证浏览器会话"。
//
// 它只做一件事：把浏览器内核里的凭证取出来。三端的内核 API 完全不同
// （CDP / CookieManager / WebKitGTK），但只要能返回这两样东西，
// 上层的轮询、放行判定、事件通知就完全一样。
type session interface {
	// Cookies 返回该域名下可用的 cookie 串（含 HttpOnly），形如 "a=1; b=2"。
	// 应当是"读当前值"，会被反复调用（每 600ms 一次）。
	Cookies(ctx context.Context) (string, error)
	// UserAgent 是完成验证所用浏览器的 UA。
	// cf_clearance 与 UA 绑定，必须与 cookie 一起回填，否则验证过了仍 403。
	UserAgent() string
	// Close 释放连接/覆盖层。
	Close()
}

// pageInspector 是可选能力：能判断"页面是否已放行"并取渲染结果。
//
// 只有 CDP 能低成本做到（Android 也能，但要额外一层 evaluateJavascript）；
// 拿不到这个能力的平台退化为"只看 cf_clearance"，不影响主路径。
type pageInspector interface {
	Passed(ctx context.Context) (bool, error)
	HTML(ctx context.Context) (string, error)
}
```

`solve()` 改成：

```go
func solve(c lgnet.Challenge, bus port.EventBus) (lgnet.ChallengeResult, error) {
	ctx, cancel := context.WithTimeout(context.Background(), verifyTimeout)
	defer cancel()

	sess, err := openSession(ctx, c.URL)   // ← 唯一的平台分叉点
	if err != nil {
		return skip("打开验证会话失败: " + err.Error())
	}
	defer sess.Close()

	// 浏览器里已有凭证就复用，不必弹窗（profile 是持久的）
	if all, err := sess.Cookies(ctx); err == nil && HasCookie(all, "cf_clearance") {
		return lgnet.ChallengeResult{Cookie: all, UserAgent: sess.UserAgent()}, nil
	}

	w := openVerifyWindow(c)               // 平台差异由 build tag 处理
	defer w.close()

	// 轮询 —— 三端共用
	for {
		poll(ctx)
		all, err := sess.Cookies(ctx)
		if err == nil && HasCookie(all, "cf_clearance") {
			return lgnet.ChallengeResult{Cookie: all, UserAgent: sess.UserAgent()}, nil
		}
		if pi, ok := sess.(pageInspector); ok {   // 兜底
			...
		}
	}
}
```

**净效果**：`solve()` 里不再出现 `cdpPort`、`DialBrowser`、`PageEval`，这些下沉到 `session_cdp.go`。

---

## 2. 三端实现

### 2.1 Windows · WebView2

**现状可用**，两条路择一。

| 路径 | 机制 | 状态 |
|---|---|---|
| A. CDP 端口（现用） | `--remote-debugging-port` + `Storage.getCookies` | 已实现，能用 |
| B. fork 补丁（推荐终态） | 进程内 `edge.Chromium.CallDevTools("Network.getAllCookies")` | 见 `WAILS-FORK-COOKIE.md` |

`session_cdp.go`（`//go:build !android`）：

```go
type cdpSession struct {
	conn *cdp
	ua   string
	domain string
}

func (s *cdpSession) Cookies(ctx context.Context) (string, error) {
	all, err := s.conn.Cookies(ctx)
	if err != nil {
		return "", err
	}
	return DomainCookie(all, s.domain), nil   // 复用现有函数
}

func (s *cdpSession) UserAgent() string { return s.ua }
func (s *cdpSession) Close()            { s.conn.close() }

func (s *cdpSession) Passed(ctx context.Context) (bool, error) { ... }
func (s *cdpSession) HTML(ctx context.Context) (string, error) { ... }
```

**注意**：`cdpSession` 只是把现有 `cdp.go` 包一层，`DomainCookie`/`HasCookie`/`PageEval` 一行不用改。

**为什么不用 WebView2 官方的 `ICoreWebView2CookieManager`**：
Wails 里那段绑定是坏的 —— `ICoreWebView2CookieManager.GetCookies(uri)` 把 `&list` 当成 **CompletedHandler** 传给异步 COM API，而这个包里**根本没有 CompletedHandler 类型**；`cookies_test.go` 从头到尾没调过 `GetCookies`。用它会在运行时崩。

---

### 2.2 Android · WebView ← **唯一的真缺口**

API 本身极其简单：

```java
CookieManager.getInstance().getCookie(url)   // 同步，返回 "a=1; b=2"，含 HttpOnly，无需权限
```

**难点不在 API，在 Go→Java 的通道**。Wails 提供的只有包内私有的：
`androidBridgeStringString(method, arg)`（`pkg/application/application_android.go:399`）。

关键细节（已核对源码）：`callBridgeStringStringMethod` 用的是
`GetObjectClass(g_bridge)` + `CallObjectMethod`，签名 `(Ljava/lang/String;)Ljava/lang/String;` ——
**这是实例方法**。所以 Java 侧必须写成：

```java
// WailsBridge.java（我们自己的文件，版本化维护）
public String getCookie(String url) {
    try {
        return CookieManager.getInstance().getCookie(url);
    } catch (Throwable t) {
        return "";
    }
}
```

写成 `static` 的话 `GetMethodID` 找不到（静态要用 `GetStaticMethodID`），**静默返回 null** —— 这种失败最难查。

还需要 UA：

```java
public String getUserAgent() {
    return webView != null ? webView.getSettings().getUserAgentString() : "";
}
```

**补丁形态**（`third_party/wails/patches/`，新增文件、0 行修改）：

```go
//go:build android

package application

import "errors"

// LegadoCookies 从 Android WebView 的 CookieManager 读取指定 URL 的 cookie。
// 返回的串含 HttpOnly 项——这正是页面脚本读不到、而 CF 需要的凭证。
func (w *WebviewWindow) LegadoCookies(uri string) (string, string, error) {
	if uri == "" {
		return "", "", errors.New("empty uri")
	}
	cookie, ok := androidBridgeStringString("getCookie", uri)
	if !ok {
		return "", "", errors.New("getCookie 未实现（WailsBridge 版本不匹配）")
	}
	ua, _ := androidBridgeString("getUserAgent")
	return cookie, ua, nil
}
```

**还有一个 Android 独有的问题：开不了第二个窗口。**
Wails 安卓只支持首个窗口，不能像 Windows 那样 `app.Window.NewWithOptions(...)`。

两条路：

| 做法 | 说明 | 代价 |
|---|---|---|
| **A. Java 侧叠一个覆盖层 WebView** | `MainActivity` 自己 `new WebView()` 加到 root view，验证完 remove | 需在 Java 侧写 ~60 行 + 一个 `//export` 回调通知 Go |
| B. 主 WebView 整页导航到目标站 | 无需新代码 | SPA 被卸载，验证完回不来；且 Wails 的 `onPageFinished` 循环可能打架 |

推荐 A。补丁再加一个导出：

```go
//export Java_com_wails_app_WailsBridge_nativeLegadoVerifyDone
func Java_com_wails_app_WailsBridge_nativeLegadoVerifyDone(env *C.JNIEnv, obj C.jobject, jurl, jcookie, jua C.jstring)
```

Java 覆盖层 WebView 的 `onPageFinished` 里读 cookie，调这个方法；Go 侧把结果塞进 channel，
`LegadoVerify(url)` 阻塞等它，语义与 Windows 的 `ChallengeHandler` 完全一致。

---

### 2.3 Linux / Flutter · WebKitGTK

迁移后不走 Wails，架构也不同：**不是 Go 回调宿主，而是 Dart 主动推给 Go**。

```dart
final cookies = await controller.getCookies(url: Uri.parse(target));
final cf = cookies.where((c) => c.name == 'cf_clearance');
if (cf.isNotEmpty) {
  await legado.call('Verify.Submit', {
    'domain': domain,
    'cookie': cookies.map((c) => '${c.name}=${c.value}').join('; '),
    'userAgent': await controller.evaluateJavascript('navigator.userAgent'),
  });
}
```

Go 侧**不需要改 `lgnet`**，只需在 `internal/adapter/verifyflutter/` 实现同样的 `ChallengeHandler`：

```go
lgnet.ChallengeHandler = func(c lgnet.Challenge) (lgnet.ChallengeResult, error) {
	wait := make(chan lgnet.ChallengeResult, 1)
	pending.Store(c.Domain, wait)
	defer pending.Delete(c.Domain)

	bus.Emit(ctx, "verify:request", map[string]any{"domain": c.Domain, "url": c.URL})

	select {
	case r := <-wait:                       // Dart 调 Verify.Submit 后投递
		return r, nil
	case <-time.After(3 * time.Minute):
		return lgnet.ChallengeResult{Skip: true}, nil
	}
}
```

`Verify.Submit` 的实现就是 `pending.Load(domain)` 后发进 channel。
**这样 `lgnet` 一行不改** —— `ChallengeHandler` 这个同步回调本身就能承载异步语义。

---

## 3. 五个必须处理的坑

### 3.1 UA 必须与 cookie 成对

`cf_clearance` 与 UA 绑定。WebView 的 UA ≠ Go 的默认 UA。
现有 `ApplyChallengeResult` 已做 `ReplaceCookie` + `SetUserAgentOverride`，**别绕过它直接写 cookie**。

Windows 要从 CDP 的 `/json/version` 取（`User-Agent` 字段），Android 从 `WebSettings` 取，
Flutter 从 `navigator.userAgent` 取 —— 三处都要取到，不能留空。

### 3.2 按 eTLD+1 聚合，不是按完整 host

`cf_clearance` 常挂在 `.example.com` 上。用 `www.example.com` 去精确匹配会漏。
现有 `DomainCookie(all, domain)` 已经按"等于 或 后缀匹配"处理，复用即可。

### 3.3 完成判定看 cookie，不看 DOM

现有逻辑的顺序是对的：**先判 `cf_clearance`，再退回 `pagePassed`**。

`pagePassed` 有个 `minDwell = 5s` 的延迟，因为挑战页 load 完时 JS 还没跑起来。
这个延迟在 Android 上同样需要（若实现 `pageInspector`），否则会把挑战页当正文。

### 3.4 `cf_clearance` 有 TTL，过期只能重新验证

默认 30 分钟（站点可配 5 分钟 ~ 1 年）。过期后不是"重试"，是"重新弹窗"。
现有设计已经隐式正确：cookie 存在 `CookieStore` 里，只有真的 403 挑战才触发 `RunChallenge`。
**不要**加"定时刷新"，那会平白多弹窗。

### 3.5 无头场景无解，必须明确降级

后台下载、定时刷新时没有 UI，也开不了验证窗口。
`ChallengeHandler == nil`（或平台未实现）时 `RunChallenge` 返回 `false`，引擎原样返回被拦截的响应 ——
这是正确行为。产品文案应写明"后台任务遇到人机验证会暂停，等打开 App 后继续"。

---

## 4. 落地顺序

| 步 | 内容 | 风险 | 依赖 |
|---|---|---|---|
| **S1** | 抽 `session` 接口，Windows 用现有 CDP 包一层 | 低（行为不变，靠现有测试兜） | 无 |
| **S2** | Android：`WailsBridge.java` 加 2 个实例方法 + fork 补丁加 `LegadoCookies` | 中（需真机验） | fork 仓库 |
| **S3** | Android：覆盖层 WebView + `nativeLegadoVerifyDone` 回调 | 中 | S2 |
| **S4** | Flutter：`verifyflutter` 适配器 + Dart 侧 `getCookies` | 低 | 迁移到 C 阶段 |
| S5（可选） | Windows 换用 fork 补丁，去掉调试端口 | 低 | fork 仓库 |

**S1 可以立刻做且不改变任何行为**，做完之后 S2/S3 只是在 `session_android.go` 里填一个函数。

---

## 5. 每端验收标准

不靠肉眼，靠一条可复现的判定：

```bash
# 引擎侧：挑战检测与凭证回填
go test ./pkg/net -run TestChallenge

# 宿主侧：给定一个已知 CF 站点，走完流程后
# 1) CookieStore 里出现 cf_clearance
# 2) 同一域名后续请求不再返回 403 + cf-mitigated
```

Android 端额外一条（最容易漏）：

```java
// 必须能读到 HttpOnly 项，否则说明拿的是 document.cookie 而不是 CookieManager
String c = CookieManager.getInstance().getCookie("https://目标站/");
assert c.contains("cf_clearance");
```
