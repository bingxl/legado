# 进度 · 网络层（net）

> 目录：`packages/legado_core/lib/src/net/`、`packages/legado_core/test/net/`
> 状态：**完成**。`dart test test/net` 126 例全绿（约 1.5s，全回环不出网），`dart analyze lib/src/net test/net` 零 issue。

## 一、能力清单

| 文件 | 能力 |
| --- | --- |
| `cookie_store.dart` | RFC 6265 cookie jar：`domain + path + name` 三元组独立存；域匹配（host-only / 带 Domain 含子域）、path 匹配、过期清理、`__Host-` / `__Secure-` 前缀校验、`Expires` 日期解析（三种格式）、JSON 持久化、WebView 导入、`toJson()/fromJson()` 纯内存序列化（接数据库 `cookies` 表用） |
| `charset.dart` | 编码探测：BOM → 显式 charset → Content-Type → meta/xml 声明 → UTF-8 合法性启发式 → GBK 兜底。支持 UTF-8 / GBK(GB2312/GB18030) / UTF-16LE/BE / ISO-8859-1；`encode()` 反向编码（GBK 搜索参数用） |
| `rate_limiter.dart` | 每 host 并发（默认 3）+ 每 host 最小间隔（默认 100ms）+ 全局并发（默认 16）+ 连续失败 3 次退避 5s；槽位「直接转交」避免限流器经典死锁 |
| `cloudflare.dart` | 只认 `cf-mitigated: challenge`（2xx 不判、`Server: cloudflare` 不判）；`CloudflareGuard` 委托宿主 → 合并写入 cookie + UA 覆盖 → 只重试一次；无 handler 抛 `CloudflareChallengeException`；同 host 验证串行 |
| `http_client.dart` | `LegadoHttpClient`：底层 `IOClient`；手动跟重定向（逐跳存 cookie、`finalUri`、303 降级 GET）；Cookie 自动收发与合并；gzip/deflate 解压；超时；连接错误指数退避重试；可选系统代理；日志脱敏；`sendStream()` 流式响应（下载器用） |
| `downloader.dart` | `Downloader`：断点续传（`Range` + 206 追加 / 200 覆盖 / 416 已完成）、`.part` 原子落盘、并发闸门复用 `RateLimiter`、`CancelToken`、按块进度、网络错误重试、4xx 不重试、100MB 上限 |
| `net.dart` | `NetClient` 门面：`get/post/postForm/postJson/send/sendStream/withHeaders`、cookie 存取、`encodeForm`（GBK 参数编码） |

测试分布：`cookie_store_test` 34 例、`charset_test` 21 例、`http_client_test` 32 例、`rate_limiter_test` 8 例、`cloudflare_test` 13 例、`downloader_test` 18 例。

## 二、门面接入（请主控做）

**主控已决定不导出到 `lib/legado_core.dart`**：net 是内核内部能力，包内直接
`import '../net/net.dart'`。`net.dart` 已 `export` 了 charset / cookie / cloudflare /
http_client / rate_limiter / downloader 的全部公开符号，包内只 import 这一个文件即可。

典型用法：

```dart
final net = NetClient(onChallenge: (req) => webview.solve(req));  // App
await net.loadCookies('$homeDir/cookies.json');   // 或 net.cookies.fromJson(dbRow)
final resp = await net.get(uri, charset: 'gbk');  // charset 可省略，走自动探测
await net.saveCookies('$homeDir/cookies.json');

final downloader = Downloader(client: net, maxConcurrent: 3);
await downloader.download(
  DownloadTask(uri: imgUri, savePath: p, headers: {'Referer': chapterUrl}),
  onProgress: (p) => ui.setProgress(p.received, p.total),
  cancel: token,
);
```

数据库接入（服务层，不需要 import store）：

```dart
// 写
final row = jsonEncode(net.cookies.toJson());
// 读
net.cookies.fromJson(jsonDecode(row) as Map<String, Object?>);  // 合并，不清旧值
```


## 三、没做的（与原因）

1. **Brotli 解压**：无纯 Dart 实现。已在 `_buildHeaders` 里主动从 `Accept-Encoding` 剔除 `br`，
   避免服务端返回无法处理的字节。若将来要支持，加 `brotli` 包即可，改动点只有 `_decompress`。
2. **HTTP/2**：`dart:io` 的 `HttpClient` 只有 HTTP/1.1。书源站点绝大多数是 1.1，收益低。
3. **证书固定 / 忽略证书校验**：`IOClient` 默认校验。原版 legado 有 `SSLHelper`（可配置跳过证书校验），
   Dart 侧需要在 `HttpClient.badCertificateCallback` 上做，属于 App 侧安全策略，等主控定方案。
   目前遇到自签证书站点会抛 `HandshakeException`（已在重试逻辑里覆盖，但重试也必然失败）。
4. **`SameSite` 语义**：只存不判。纯 Dart 侧没有浏览器的跨站请求模型，判了也没有意义。
5. **Public Suffix List**：`Domain=com` 这类越权 cookie 会被接受（RFC 的 domain-match 允许），
   浏览器会用 PSL 拒绝。书源场景里没人会这么发，不值得引 PSL 数据。
6. **Cookie 超 4096 字节随机丢弃**：原版 `CookieStore.getCookie` 有这段逻辑（Android 头部长度限制），
   这里没做——Dart 侧没有 4KB 限制，强行丢 cookie 只会让登录态随机失效。
7. **`HttpRequest` 之外的 multipart 上传**：书源用不到，留给需要上传封面的场景。
8. **下载分片 / 多连接加速**：单连接顺序下载。漫画站单页几十 KB，加速收益小、复杂度高。
9. **下载断点跨进程保留**：按契约「失败/取消删 `.part`」，所以跨进程只能靠「目标文件已存在」
   续传。若要保留 `.part`，把 `_deleteQuietly` 的两处调用去掉即可（`.part` 不会被误认成完整文件）。

## 四、留给谁

| 事项 | 接手方 |
| --- | --- |
| WebView 取 `cf_clearance` 并回填 `ChallengeSolution` | App 侧（UI 阶段） |
| 书源 `header` 字段 → `NetClient.withHeaders` | rules（规则引擎） |
| 搜索关键字按源编码（`charset`）→ `postForm(charset: 'gbk')` / `encodeForm` | rules |
| `concurrentRate` / 每源限速 → 复用 `RateLimiter.run(host, ...)` | rules 或服务层 |
| cookie 落盘路径（`$homeDir/cookies.json`）/ `cookies` 表读写 → `toJson/fromJson` | 服务层 |
| 封面 / 插图 / 漫画页下载调用点 → `Downloader.download` / `downloadAll` | 服务层 |
| 下载进度的 UI 展示（节流后 `setState`） | App/UI |

## 五、踩过的坑（按坑的杀伤力排序）

1. **`Expires=Wed, 21 Oct 2015 07:28:00 GMT` 里的逗号**。
   按逗号切分属性会把日期劈成两半；更隐蔽的是 `package:http` 的 `IOStreamedResponse`
   **把多个 `Set-Cookie` 头 join 成一行 `', '`**，拿回来时必须再切分一次
   （`splitSetCookieHeader`，规则是「逗号后紧跟 `name=`」才算新条目）。这条链路错了，
   表现为「登录成功但只保留了一半 cookie」。
2. **限流器的死锁**。第一版是「释放时 active--，再唤醒一个排队者」，被唤醒的协程发现队列
   非空又把自己排回队尾，最终没人再唤醒它 → 整个 host 永久卡死。改成「槽位直接转交」
   （有排队者时 active 不减，直接把名额给它）。
3. **重定向要自己走**。`IOClient` 默认让 `dart:io` 自动跟随，但那样拿不到中间跳的
   `Set-Cookie`（302 上带 session 的登录链路必崩），也拿不到每一跳的 URL。
   现在统一 `followRedirects=false` + 手动循环，逐跳落 cookie、逐跳重算 Cookie 头。
4. **`cf_clearance` 与 UA 绑定**。验证通过后如果不把 UA 换成浏览器的，Cloudflare 仍判 403，
   现场表现是「验证窗口明明过了，正文还是空」。所以 UA 覆盖优先级最高，压过书源自己配的 UA。
5. **写 cookie 不能用 `Set-Cookie` 语义**。WebView 拿回来的是完整集合，套 `Set-Cookie`
   会把没有 Expires 的项降级成会话 cookie、把 host-only 补成 Domain，把登录态挤掉。
   单独开了 `replaceFromWebView` / `importCookieHeader` 两个入口，并且是**合并**写入。
6. **`gbk_codec` 的 `gbk` 编码器对多字节是按单字节查表的**（`gbkDecode` 只查 `_gbkCode_to_char[byte]`，
   多字节永远查不到）。必须用 `gbk_bytes`，`gbk` 那个是坏的。它的 encoder 对表外字符会把
   codeUnit 直接写进字节流（>0xFF），所以 `charset.encode()` 里做了截断。
7. **`dart:io` 的 gzip 自动解压只在自己加的 `Accept-Encoding` 上生效**。书源手动塞了
   `Accept-Encoding` 就会拿到未解压字节。用 gzip 魔数 `1F 8B` 判定可以同时覆盖两种情况，
   且不会二次解压。
8. **`DateTime.now()` 精度不足以排序 cookie**。同一毫秒写入的多条 cookie，
   排序会变成随机顺序（Dart 的 `sort` 不稳定），导致 `Cookie` 头每次请求都不一样——
   有签名校验的站点会随机失败。容器内统一盖单调递增的 `createdAt`。
9. **2xx 不能判 Cloudflare**。早期还用过正文特征（`Just a moment...`）做第二判据，
   结果书源页脚、评论区里出现同款字样就弹验证窗口。现在只认响应头。
10. **`Window` 上 `rename` 不能覆盖已存在的文件**。原子落盘时如果目标文件已存在，
    `File.rename` 会抛 `FileSystemException`。必须先 `delete` 再 `rename`——
    有一个极短的「目标已删、新文件还没改名」的窗口，但总比留下半个文件强。
11. **小响应体在回环里只到一个 chunk**。8KB 的响应即使服务端分 8 次 `flush`，
    客户端也只收到 1 个 chunk，于是「传输中途取消」这条路测不到；测试里必须用
    512KB 才能稳定拿到多 chunk。同理，**进度回调的粒度由网络读决定，不是写入粒度**，
    UI 必须自己做节流，否则一张图会触发几十次 `setState`。
12. **下载必须显式 `Accept-Encoding: identity`**。否则 `dart:io` 会自动加 gzip 并解压，
    而 `Content-Length` 是压缩后的长度 → 进度停在 100% 却还没写完。
13. **`Range` 请求拿到 206 时要校验 `Content-Range` 的起始偏移**。服务器换了文件内容时
    偏移会对不上，直接追加会得到「半新半旧」的坏文件；偏移不符就退化成整份重下。
14. **POST 的 body 必须带对 Content-Type，否则请求体被当二进制丢掉**。
    `NetClient.post` 只有在 body 是 `String`/`Map` 时才会推断并带上
    `Content-Type`；直接给 `List<int>` 就没有任何 Content-Type。
    症状极具迷惑性：接口返回 **HTTP 200**，内容却是
    `{"code":"-1","msg":"没有更多数据了","data":""}`——PHP 站点读不到
    `$_POST`，当作「没数据」。服务层现在按 body 形态分流：
    表单 → `encodeFormBody`（百分号转义 + 按目标编码取字节）+ 显式
    `application/x-www-form-urlencoded`；JSON → 交回网络层推断
    `application/json`；规则自己声明了 Content-Type → body 原样发送。

## 六、已知缺陷

- 代理只认 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量，且 `useSystemProxy` 默认 **false**。
  Windows 系统代理（注册表 / PAC）读不到，需要 App 侧显式传 `useSystemProxy: true` 或自行注入。
- `maxRedirects` 超限时返回最后一个 3xx 响应而不是抛异常（与原版 OkHttp 行为不同，
  但更利于书源容错——很多站点会返回 302 到登录页）。
- 超时后底层 socket 不会被取消（Dart 的 `Future.timeout` 只是不再等待），
  极端情况下会多占一个连接，直到 `idleTimeout`（15s）回收。
- `Cookie` 的 `sameSite` 只做保留，不参与发送判定。
- `Downloader` 的并发闸门是**实例级**的：`maxConcurrent` 只约束同一个 `Downloader` 上的调用。
  服务层请复用同一个实例，否则「3 并发」会变成「每个实例 3 并发」。
- `Downloader.close()` 会关掉内部闸门，之后再用会抛 `StateError`；它**不**关闭 `NetClient`。
- 下载没有「整体超时」：只有建连/响应头受 `NetClient.timeout` 约束，慢速传到一半的
  连接会一直挂着。需要时由调用方用 `CancelToken` 兜底。
