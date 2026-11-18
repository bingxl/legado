# Cloudflare 验证通过方案调研（含 Go 侧能力边界）

> 调研时间：2026-11-18。目的：判断本项目（自用阅读器 + 1988 条书源）的 CF 验证该用什么形态，
> 以及是否存在「纯 Go 侧通过验证」的方案。结论先行，证据在后。

---

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| 有纯 Go 库能过 CF 吗？ | **只能过前两层**（TLS 指纹、HTTP/3）。JS 挑战与 Turnstile 不行，这是设计上的边界，不是库不够好 |
| 有 Go 侧完整方案吗？ | 只有「Go 驱动真实浏览器」（go-rod/chromedp + 反检测），本质还是真实浏览器在解 |
| 弹 UI 让用户手动操作可行吗？ | **可行，而且是本项目唯一正确形态**。原版 legado 就是这么做的 |
| 现有 `pkg/net/challenge.go` 是否要改？ | **架构不用改**。只需补两端「从浏览器内核读 HttpOnly cookie」的实现 |
| 要不要引入 TLS 指纹库？ | 可选优化，非必需。本项目用户是真实住宅 IP + 真实浏览器，本就不该被拦 |

---

## 1. Cloudflare 的评分模型：五层，任一层错就挂

CF 不是「一道题」，而是四个（现在是五个）维度**同时打分**，通过三层失败一层依然被拦。

| # | 层 | 它看什么 | 能否在 Go 里伪装 |
|---|---|---|---|
| 1 | IP 声誉 | ASN、是否数据中心段、历史行为、同 IP 其他访客 | ❌ 只能换出口 IP（住宅代理），代码解决不了 |
| 2 | 协议指纹 | TLS ClientHello（JA3/JA4）、HTTP/2 SETTINGS 与伪头顺序、HTTP/3 QUIC 参数 | ✅ 纯 Go 可做，有成熟库 |
| 3 | JS 挑战 | `_cf_chl_opt`、`/cdn-cgi/challenge-platform/`、Managed Challenge 的 JS VM | ❌ 必须真 JS 引擎 + 真浏览器环境 |
| 4 | Turnstile | 无感模式（采集指纹）/ 交互模式（勾选框） | ❌ 交互模式必须人工点击 |
| 5 | 行为 | 鼠标轨迹、滚动深度、键击节奏、请求间隔 | ❌ 真人天然通过，脚本很难伪装 |

**关键认知**：第 2 层能纯库过，所以很多人以为「过了 TLS 指纹就过了 CF」。实际上第 3~4 层才是 403 的主要原因。
反过来，**真实浏览器把 2~5 层全部天然满足**，唯一缺的只是第 1 层（但用户自己就是住宅 IP）。

---

## 2. 主流方案族谱（5 类）

### A. TLS 指纹模拟库

代表：`curl_cffi` / `curl-impersonate`（C/Python）、`bogdanfinn/tls-client`（Go）、`uTLS`（Go 底层）

- 原理：复刻真实浏览器的 ClientHello + HTTP/2 帧设置 + 头顺序，让 JA3/JA4 与真 Chrome 一致。
- 能过：Bot Fight Mode、纯指纹规则（错误码 1010）。
- 不能过：任何 JS 挑战。这一点 `unblock` 的 README 写得最直白：
  > *"It does not execute JavaScript. A managed Cloudflare challenge (Turnstile, the 'Checking your browser' page that computes a token) still cannot be bypassed — fingerprints only win against rules that are purely TLS/h2 based. The package tells you that this is what happened (`CF_CHALLENGE`) instead of pretending to solve it."*
- Go 生态成熟度：`tls-client` 已是事实标准（HTTP/1.1 + h2 + h3、header order、protocol racing、cookie jar，甚至有 JS/Python/C# 的 FFI 绑定）。

### B. 反检测浏览器

代表：`nodriver`（undetected-chromedriver 后继）、`SeleniumBase UC Mode`、`Camoufox`（Firefox 分支，C++ 层改指纹）、`Patchright`、`go-rod + unrevealed`（Go）

- 原理：真实浏览器 + 抹掉自动化痕迹（`navigator.webdriver`、CDP 泄漏、headless UA）。
- 能过：JS 挑战、部分 Turnstile（`SeleniumBase` 的 `uc_gui_click_captcha()` 用 pyautogui 模拟**真实鼠标**去点勾选框，这是它能过的原因——不是"破解"，是"真的点了"）。
- 代价：每个实例 200~340MB 内存、1~3 秒冷启动，需要系统装 Chrome/Chromium。
- **网上流传的过验证率数字不要当真**：同一批目标，一家测出 nodriver 89.4% / SeleniumBase 96.4%，另一家测出 nodriver 28/31、Camoufox 25/31、stock Playwright 24/31，排序都不一致。这些是单日单目标的采样，不是稳定指标。

### C. 容器化浏览器代理

代表：`FlareSolverr`、`Byparr`（维护更活跃的 fork）

- 形态：独立进程/容器，暴露 HTTP 接口，内部跑无头浏览器，返回 HTML + cookies + UA。
- 优点：任何语言都能用，Go 只需发 HTTP。
- 现状：2026 年的多篇评测都在建议**新项目跳过它**（"Skip FlareSolverr for new work"），因为追赶 CF 更新慢、吃内存、Turnstile 也过不了。
- 对本项目：多一个进程 + 一个端口，与「包体小、内存小」约束直接冲突。

### D. 托管解题 API

代表：`NSLSolver`、`ScrapingBee`、`Scrapfly`、`2Captcha`

- 形态：POST 目标 URL → 返回 `cf_clearance` + 匹配的 UA，或 Turnstile token。
- 价格量级：CF Challenge 约 $0.5/1000 次，Turnstile 约 $0.4/1000 次。
- **对本项目是死路**：见 §4.2。

### E. 真人浏览器（用户手动）

代表：内嵌 WebView（原版 legado 的 `WebViewActivity`）、系统浏览器 + 回调

- 原理：不做任何伪装，就是让真人在真浏览器里点一下。CF 要的就是这个。
- 能过：全部五层。
- 唯一难点：`cf_clearance` 是 **HttpOnly**，页面 JS 读不到，必须从浏览器内核（CookieManager/CDP）取，再交给 Go。

---

## 3. Go 侧的真实能力边界

### 3.1 能拿到手的两个库

**`bogdanfinn/tls-client`**（MIT，事实标准）

```go
client, _ := tls_client.NewHttpClient(tls_client.NewNoopLogger(),
    tls_client.WithClientProfile(profiles.Chrome_150),
    tls_client.WithRandomTLSExtensionOrder(),
    tls_client.WithCookieJar(tls_client.NewCookieJar()),
)
```

特性（README 明列）：HTTP/1.1 + HTTP/2 + HTTP/3、Protocol Racing、TLS 指纹、HTTP/3 指纹、自定义头顺序、代理、Cookie Jar。
注意它返回的是 `bogdanfinn/fhttp` 的 `*Response`，不是标准库类型，接入现有 `pkg/net` 需要一层转换。

**`nyelonong/unblock`**（MIT，v0.3.0，2026 年新库，较薄）

在 tls-client 之上封装了「分类 + 阶梯重试」，**它的分类逻辑与本项目 `challenge.go` 完全一致**：

| 它识别的标记 | 用途 |
|---|---|
| `cf-mitigated: challenge` | 需浏览器执行 JS |
| `_cf_chl_opt` / `Just a moment` | 同上（弱信号） |
| `Error 1010` | 浏览器指纹被封 |
| `Error 1009` | 国家封锁 |
| `Error 1015` | 限流，需冷却 |
| `Error 1020` | ASN/机房 IP 被规则拒绝 |

这反过来验证了本项目用 `cf-mitigated: challenge` 作唯一强信号的判断是对的。

它有一个本项目参考价值最高的结论 —— **HTTP/3 是单点最强的杠杆**：

> *"Measured on a Cloudflare-protected page where **every** recent profile was blocked over HTTP/2 (403), protocol racing returned 200 over HTTP/3 — with chrome_133 and with chrome_150. It is the single strongest lever here: stronger than changing profiles, and stronger than forcing HTTP/1.1."*

以及一个必须知道的限制：**HTTP/3 走不了 HTTP 代理**（CONNECT 只能隧道 TCP，QUIC 是 UDP）。设了 `ProxyURL` 时 protocol racing 会被自动忽略，否则真实 IP 会裸露。

### 3.2 一个「半自动」的参考实现：`luinor223/cloudfetch`

这个库的形态与本项目最接近，值得抄思路：

1. uTLS 复刻浏览器指纹；
2. 用 **goja（纯 Go JS 引擎）** 自己解经典 IUAM 挑战页；
3. 解不了时 **browser handoff** —— 交给 headless Chrome 过一次，把含 `cf_clearance` 的 cookie 存下来，并**把浏览器身份头（UA、`sec-ch-ua*`）一并接管**，后续请求都用这个身份。

它自己也承认局限：头顺序和 h2 设置来自 Go 的 `net/http`（不是浏览器），Managed/Turnstile 直接返回 `ErrManagedChallenge`。

**对本项目的启示**：第 3 步正是我们该做的，只是把「headless Chrome」换成「App 内 WebView + 用户手动点」。用户的 WebView 比它的 headless Chrome 更真。

### 3.3 结论：纯 Go 通过验证是不可能的

不是"暂时没有库"，而是**结构上不可能**：

- 第 3 层要求执行 CF 下发的、动态生成的、针对本次会话混淆的 JS；
- 第 4 层交互式 Turnstile 要求一次真实的人类点击（SeleniumBase 的做法是调 pyautogui 移动真实鼠标，这已经是"外挂硬件输入"而不是"算法"）；
- 第 5 层要求行为熵。

想在 Go 里做，只能把 V8/SpiderMonkey 整个嵌进来 + 伪造 GPU/Canvas/Audio 上下文 —— 那就是在 Go 里重造一个浏览器，工作量与维护成本远超方案 B。

---

## 4. 三个必须提前排除的死路

### 4.1 本地回环代理（Loopback Proxy）——看着很妙，实际无效

想法：Go 起一个 `127.0.0.1:port` 的 HTTP 代理，WebView 设代理指过来，Go 就能在代理层看到所有 `Set-Cookie`，**包括 HttpOnly**，且跨三端统一。

**否决理由**：目标站全是 HTTPS。代理对 HTTPS 只做 `CONNECT` 隧道，看到的是加密字节流，`Set-Cookie` 在 TLS 里面。
唯一出路是 MITM（自签 CA + 中间人解密），但这会改变证书链和 TLS 特征 —— 而 CF 正在校验这一层，等于自毁。

> 唯一还有效的变体：代理只做**域名级**统计（知道请求了哪些 host），拿不到 cookie。对本需求无用。

### 4.2 托管解题 API 的 cf_clearance —— 拿到也用不了

`cf_clearance` 绑定三要素：**出口 IP + User-Agent + TLS 指纹**。

- 托管 API 在它的机房、用它自己的 IP 解出来的 cookie，拿回用户家里发请求 → IP 不匹配 → 直接丢弃重新挑战。
- 官方文档措辞是 "securely tied to the specific visitor and device it was issued to"；社区实践总结得更直接："必须用同一个 IP 和 UA"。
- 换 IP 之后的表现是"随机的偶发失败"，极难排查。

> 同理：任何"帮别人解 CF"的服务，只在**同一条出口**上跑完整链路时才有效。这恰好说明「验证与使用必须在同一个进程/同一个 IP 上」，也就是 App 内 WebView。

**同一个坑还有两个变体**，本项目已经踩过其中一个：
- 换了 UA 但 cookie 还是旧的 → 失效。所以 `ChallengeResult.UserAgent` 必须和 cookie 一起回填（`challenge.go` 已实现）。
- `cf_clearance` 默认 TTL 30 分钟（Challenge Passage，站点可配 5 分钟 ~ 1 年）。过期后不能"重试"，只能"重新验证"。

### 4.3 用 cookie 判定是否已验证 —— 会误判

CF 的挑战页**可以用 200 状态码返回**。所以：
- 不能只看状态码；
- 也不能只看"cookie 里有没有 cf_clearance"（可能已过期但仍存在）；
- 必须看响应标记（`cf-mitigated` / 正文特征），这正是 `IsCloudflareChallenge()` 现在做的事，且刻意把 2xx 排除在正文匹配之外 —— 这个设计是对的。

---

## 5. 本项目的裁定

### 5.1 场景与爬虫完全不同，不要套爬虫的思路

| 维度 | 典型爬虫 | 本项目 |
|---|---|---|
| IP | 机房 IP，声誉差 | 用户家里的住宅 IP |
| 频率 | 每分钟数百请求 | 一章一请求，读书节奏天然慢 |
| 浏览器 | 没有，要造一个 | App 里本来就有（WebView2 / Android WebView / WebKitGTK） |
| 用户 | 不在场，要全自动 | 在场，正在等这本书 |
| 目标 | 批量拿数据 | 用户自己的账号，读自己要看的内容 |

结论：**A/B 两类的核心价值（伪装成浏览器）对本项目几乎为零**，因为本来就有真浏览器；
我们唯一的技术缺口是 **HttpOnly cookie 读不到 Go 侧**。

### 5.2 现有架构已经是对的，不要推翻

`pkg/net/challenge.go` 的形态：

```
请求 → 命中挑战 → Challenge{URL,Domain,Status,Reason}
     → ChallengeHandler（宿主实现，弹窗/开窗/等用户）
     → ChallengeResult{Cookie, UserAgent, Body, Skip}
     → ReplaceCookie + SetUserAgentOverride → 重试一次
```

这五项设计都是必要且已经做对的：

1. 检测放在 **net 层**（所有出口共用），验证一次对搜索/详情/目录/正文/图片/音频全链路生效；
2. 只认 `cf-mitigated` 强信号，2xx 不判；
3. 用 `ReplaceCookie` 而非 `SetCookie`（合并没有踢掉登录态）；
4. **cookie 与 UA 一起回填**（少了这步必然继续 403）；
5. 同域名 `sync.Mutex` 串行（并发抓章节不会弹 N 个窗口）；
6. `NoChallenge` 防止验证后的重取再次弹窗（否则死循环弹窗）；
7. `ChallengeResult.Body` 允许"拿不到 cookie 但页面已渲染"时直接当响应体用。

**这套东西不需要重写，只需要在两端把它接完。**

### 5.3 唯一要补的：三端读 HttpOnly cookie

| 端 | 途径 | 状态 |
|---|---|---|
| Windows | WebView2 `ICoreWebView2CookieManager`（官方）或 CDP `Network.getAllCookies` | 已有 CDP 端口方案；fork 补丁方案见 `WAILS-FORK-COOKIE.md` |
| Android | `android.webkit.CookieManager.getInstance().getCookie(url)` —— 一行，含 HttpOnly | **未实现**，当前只打日志 |
| Linux（Flutter） | WebKitGTK `webkit_cookie_manager_get_cookies()`；`flutter_inappwebview` 已封装 | 迁移时随 `flutter_inappwebview` 到位 |

### 5.4 可选优化：要不要引入 TLS 指纹库

**推荐：暂不引入，留接口。**

理由：
- 用户是真实住宅 IP + 真实浏览器验证，第 2 层本来就该过；
- 引入 `tls-client` 会带来 `fhttp` 那套非标准 `*Response`，要在 `pkg/net` 加一层适配；
- Chrome profile 需要跟着版本更新（`Chrome_150` 明年就"旧"了），是持续维护成本；
- 单一 CDN/WAF 若只做指纹规则（错误码 1010），此时才真正需要它。

如果将来要加，建议形态：
```go
// pkg/net/client.go
type Options struct {
    ...
    // Fingerprint 非空时用浏览器指纹栈发请求（需注入实现，避免引擎依赖具体库）
    Fingerprint string // "" | "chrome" | "firefox"
}
```
由宿主注入实现（像 `ChallengeHandler` 那样），引擎本身不依赖 `tls-client`，保持 `go.mod` 干净 ——
这和现在 `ChallengeHandler` 的可插拔风格一致。

### 5.5 分层的目标形态

```
L0 基线（必做）  真实 WebView 让用户手动过 → 读 HttpOnly cookie + UA → 回填 → 重试
L1 兜底（已有）  拿不到 cookie 但页面渲染成功 → 用 ChallengeResult.Body 当响应体
L2 优化（可选）  tls-client 指纹通道，用于"非挑战请求"降低触发率
L3 自动（可选）  桌面端 Go 驱动系统 Chrome + stealth（仅当用户机器装了 Chrome）
L4 无头降级      没有 UI 时（后台下载/定时刷新）：只用缓存，失败则挂起等用户回来
```

**L4 必须明确写进产品文案**：headless 模式下 CF 验证无解，只能等用户。不要试图用任何自动方案兜住，
那会引入一个永远不稳定、且随 CF 更新而失效的模块。

---

## 6. 一个反直觉的提醒

网上大量「Golang 过 CF」的文章，实际测的站点多半只是 **Bot Fight Mode**（纯指纹规则），
或者把「过了 TLS 指纹后拿到了 200」当成成功 —— 但那个 200 的响应体其实是挑战页。

判断是否真的通过，只有一条可靠标准：

```go
// 不是看状态码，是看响应是否还是挑战页
if ok, reason := net.IsCloudflareChallenge(status, headers, body); ok {
    // 没过
}
```

以及第二层验证：**正文里能否解析出书源规则要的字段**。`challenge.go` 的 `hit` 语义应该扩展到
「规则命中数」，这与 `ARCHITECTURE-V2.md` 里 Trace 的 `hit` 字段是一回事。

---

## 7. 参考

| 项目 | 用途 | 许可 |
|---|---|---|
| [bogdanfinn/tls-client](https://github.com/bogdanfinn/tls-client) | Go TLS/H2/H3 指纹客户端 | MIT |
| [nyelonong/unblock](https://github.com/nyelonong/unblock) | 指纹 + 分类 + 阶梯重试；分类标记可对照 | MIT |
| [luinor223/cloudfetch](https://github.com/luinor223/cloudfetch) | uTLS + goja 解 IUAM + browser handoff | — |
| [smegg99/unrevealed](https://github.com/smegg99/unrevealed) | go-rod 反检测封装，声称过 Turnstile | MIT |
| [CF 官方：检测挑战响应](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/) | `cf-mitigated: challenge` 的出处 | — |
| [capskip: cf_clearance 复用](https://capskip.com/cf-clearance-cookie) | 绑定条件、TTL 说明 | — |
