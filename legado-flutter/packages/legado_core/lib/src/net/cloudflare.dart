/// Cloudflare 人机验证（managed challenge）的检测与处置。
///
/// 引擎自己**不破解**验证：Cloudflare 的 challenge 需要真实浏览器执行 JS、
/// 采集指纹、产出 `cf_clearance`，而这个 cookie 是 HttpOnly 的——页面 JS 读不到，
/// 只能由宿主（App 的 WebView / 桌面端的浏览器窗口）从内核里取。
///
/// 所以这里只是骨架：**检测 → 交给宿主 → 带新凭证重试一次**。
///
/// ## 判定为什么只认响应头
///
/// Cloudflare 官方文档给出的唯一可靠信号是响应头 `cf-mitigated: challenge`。
/// 实践中踩过的坑：
/// - `Server: cloudflare` 几乎所有 CF 站点都带，正常工作也带，**不能**用来判定；
/// - 正文特征（`Just a moment...`、`/cdn-cgi/challenge-platform/`）会误伤——
///   书源的页脚、评论区里恰好出现这些字样就是一次假阳性，然后弹出验证窗口；
/// - 2xx 响应一律不判：正常页面即使带 challenge 关键字也不是拦截页。
///
/// 早期 Go 版还保留了「403/429/503 + 正文特征」的第二判据，实测假阳性多于
/// 真阳性（很多站点 403 页面自己就写了 "Attention Required"），这里直接去掉。
library;

import 'dart:async';

import 'cookie_store.dart';

/// Cloudflare 用于标记「这是一个 challenge 响应」的响应头。
const String kCfMitigatedHeader = 'cf-mitigated';

/// 忽略大小写取单值响应头。
String? headerValue(Map<String, List<String>> headers, String name) {
  final direct = headers[name];
  if (direct != null && direct.isNotEmpty) return direct.join(', ');
  final lower = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == lower && entry.value.isNotEmpty) {
      return entry.value.join(', ');
    }
  }
  return null;
}

/// 是否为 Cloudflare 挑战响应。
///
/// 只认 `cf-mitigated: challenge`，且 2xx 不判。
bool isCloudflareChallenge(int statusCode, Map<String, List<String>> headers) {
  if (statusCode >= 200 && statusCode < 300) return false;
  final v = headerValue(headers, kCfMitigatedHeader);
  if (v == null) return false;
  return v.trim().toLowerCase() == 'challenge';
}

/// 判定依据，用于日志与给用户看的提示文案；不是挑战页时返回 null。
String? cloudflareChallengeReason(
  int statusCode,
  Map<String, List<String>> headers,
) {
  if (!isCloudflareChallenge(statusCode, headers)) return null;
  return 'status=$statusCode cf-mitigated: challenge';
}

/// 一次被拦截的请求。
class ChallengeRequest {
  const ChallengeRequest({
    required this.uri,
    required this.statusCode,
    this.reason,
    this.headers = const {},
    this.label = '',
  });

  /// 被拦截的原始地址。
  final Uri uri;

  /// 上游状态码（挑战页通常是 403 / 503）。
  final int statusCode;

  /// 判定依据。
  final String? reason;

  /// 被拦截请求的请求头。
  ///
  /// 验证窗口要用同样的头去加载页面：很多站点只在特定 `Referer` / `Accept`
  /// 下才发挑战，换一套默认头直接拿到 403，用户会以为「验证没用」。
  /// `Cookie` / `Content-Length` / `Host` 这类由浏览器或连接层自己管的
  /// 已在派发前剔除（见 [HostVerification.challengeHandler]）。
  final Map<String, String> headers;

  /// 发起方标识（书源名 / 订阅名），只用于验证窗口的标题。
  final String label;

  /// 归属域名（用于 UA 覆盖表的 key）。
  String get host => uri.host.toLowerCase();
}

/// 宿主完成（或放弃）验证后的回填。
class ChallengeSolution {
  const ChallengeSolution({
    this.cookie,
    this.userAgent,
    this.body,
    this.skip = false,
  });

  /// 浏览器里的完整 cookie 串，形如 `cf_clearance=xxx; __cf_bm=yyy`。
  ///
  /// 含 HttpOnly 项也没关系——宿主是从浏览器内核取的，本来就包含它们。
  final String? cookie;

  /// 完成验证所用浏览器的 UA。
  ///
  /// `cf_clearance` 与 UA 绑定：书源自己配的 UA 如果和验证时不一致，
  /// Cloudflare 会认为凭证不属于这个客户端，验证过了照样 403。
  final String? userAgent;

  /// 宿主直接拿到的页面 HTML。
  ///
  /// 兜底用：有些站点的验证不发 cf_clearance（自建验证、只有 `__cf_bm`），
  /// 重试必然还是挑战页，此时用浏览器渲染结果当响应体反而正确。
  final String? body;

  /// 用户放弃 / 宿主不支持。
  final bool skip;
}

/// 宿主注册的回调。
typedef ChallengeHandler = Future<ChallengeSolution?> Function(
  ChallengeRequest request,
);

/// 「用内置浏览器打开页面让用户自己过验证」——对齐原版
/// `SourceVerificationHelp.startBrowser` 的入参。
///
/// 内核不关心窗口长什么样，只要求宿主：**用 [headers] 加载 [uri]**，
/// 用户过完验证后把浏览器的 cookie、UA 和最终页面交回来。
class BrowserVerificationRequest {
  const BrowserVerificationRequest({
    required this.uri,
    this.headers = const {},
    this.title = '',
    this.sourceKey = '',
    this.refetchAfterSuccess = true,
  });

  /// 要打开的地址（通常就是被拦截的那个请求）。
  final Uri uri;

  /// 加载时要带上的请求头（已剔除 Cookie 等连接层自己管的头）。
  final Map<String, String> headers;

  /// 窗口标题：书源名 / 站点域名。
  final String title;

  /// 书源地址（原版 `sourceOrigin`），用于日志和「同一源只弹一次」。
  final String sourceKey;

  /// 验证通过后是否由**内核**重新请求一次。
  ///
  /// 原版 `WebViewModel.saveVerificationResult` 的 `refetchAfterSuccess`：
  /// - true：拿浏览器攒下的 cookie 走正常 HTTP 重抓，结果最干净（默认）；
  /// - false：直接返回浏览器里的 `outerHTML`。
  final bool refetchAfterSuccess;

  String get host => uri.host.toLowerCase();
}

/// 宿主完成（或放弃）验证后的回填。
class BrowserVerificationResult {
  const BrowserVerificationResult({
    this.html,
    this.cookie,
    this.userAgent,
    this.finalUrl,
    this.skipped = false,
  });

  /// 验证后的页面 HTML（浏览器渲染结果，兜底用）。
  final String? html;

  /// 浏览器里的完整 cookie 串（含 HttpOnly 的 `cf_clearance`）。
  final String? cookie;

  /// 浏览器的 UA。`cf_clearance` 与它绑定，必须一起换。
  final String? userAgent;

  /// 浏览器最终停留的地址（可能被跳到别的域，cookie 要落在新域上）。
  final Uri? finalUrl;

  /// 用户放弃 / 宿主不支持。
  final bool skipped;

  bool get isEmpty =>
      (html == null || html!.isEmpty) &&
      (cookie == null || cookie!.trim().isEmpty);

  /// 转成 HTTP 层能直接用的凭证。
  ChallengeSolution toSolution() => ChallengeSolution(
    cookie: cookie,
    userAgent: userAgent,
    body: html,
  );
}

/// 宿主注册的「内置浏览器验证」实现。
typedef BrowserVerificationHandler = Future<BrowserVerificationResult?>
Function(BrowserVerificationRequest request);

/// 图片验证码：宿主弹一个「看图输入」的对话框，返回用户填的串；取消返回 null。
typedef CaptchaHandler = Future<String?> Function(Uri imageUri);

/// 宿主能力注册表（进程级单例）。
///
/// 为什么用全局而不是构造参数：书源、RSS、导出等模块各自 `new NetClient()`，
/// 逐个透传会把「App 注册一次」变成「改十几处构造」。注册表只在这里存一个
/// 函数指针，测试里 `register(null)` 就能回到「没有宿主」的原始行为。
class HostVerification {
  HostVerification._();

  static BrowserVerificationHandler? _browser;
  static CaptchaHandler? _captcha;

  /// 注册（传 null 表示注销，恢复到「无宿主」）。
  static void register(BrowserVerificationHandler? handler) {
    _browser = handler;
  }

  /// 注册图片验证码输入框。
  static void registerCaptcha(CaptchaHandler? handler) {
    _captcha = handler;
  }

  /// 宿主注册的浏览器验证实现（未注册为 null）。
  static BrowserVerificationHandler? get browser => _browser;

  static bool get canOpenBrowser => _browser != null;

  static bool get canSolveCaptcha => _captcha != null;

  static CaptchaHandler? get captchaHandler => _captcha;

  /// 派生给 [CloudflareGuard] 的处理器；没有宿主时返回 null。
  static ChallengeHandler? get challengeHandler {
    if (_browser == null) return null;
    return (request) async {
      final result = await _browser!(
        BrowserVerificationRequest(
          uri: request.uri,
          headers: browserSafeHeaders(request.headers),
          title: request.label.isNotEmpty ? request.label : request.host,
          // 网络层只知道展示名，不知道书源地址（那是规则层的概念）。
          // 走 `java.startBrowserAwait` 的路径会带上真正的 bookSourceUrl。
        ),
      );
      if (result == null || result.skipped) return null;
      return result.toSolution();
    };
  }
}

/// 交给浏览器加载前要剔除的请求头。
///
/// - `cookie`：浏览器有自己的 cookie jar，手动塞会与它冲突（还可能是
///   HttpOnly 值拼出来的串，语义不对）；
/// - `content-length` / `host` / `connection`：由连接层生成，手填会让
///   WebView 的请求异常；
/// - `accept-encoding`：交给浏览器协商，手动填 `br` 之类它未必解得了。
const Set<String> _browserUnsafeHeaders = {
  'cookie',
  'content-length',
  'host',
  'connection',
  'accept-encoding',
};

Map<String, String> browserSafeHeaders(Map<String, String> headers) {
  if (headers.isEmpty) return const {};
  return {
    for (final e in headers.entries)
      if (!_browserUnsafeHeaders.contains(e.key.toLowerCase()) &&
          e.value.trim().isNotEmpty)
        e.key: e.value,
  };
}

/// 没有可用 handler 时抛出。
///
/// 为什么不静默返回原响应：调用方（书源解析）拿到挑战页 HTML 只会得到
/// 「正文为空」这种无意义的结果，把原因显式抛出来才能在日志里一眼看出。
class CloudflareChallengeException implements Exception {
  CloudflareChallengeException(this.uri, {this.statusCode, this.reason});

  final Uri uri;
  final int? statusCode;
  final String? reason;

  @override
  String toString() =>
      'CloudflareChallengeException($uri, status=$statusCode, reason=$reason)';
}

/// 域名 → UA 覆盖表。
///
/// 验证通过后必须把 UA 换成浏览器的：`cf_clearance` 与 UA 绑定。
class ChallengeState {
  final Map<String, String> _uaOverrides = {};
  final Map<String, Future<void>> _locks = {};

  Map<String, String> get userAgentOverrides =>
      Map<String, String>.unmodifiable(_uaOverrides);

  String? userAgentFor(String host) => _uaOverrides[host.toLowerCase()];

  void setUserAgent(String host, String? ua) {
    final key = host.toLowerCase();
    if (ua == null || ua.isEmpty) {
      _uaOverrides.remove(key);
    } else {
      _uaOverrides[key] = ua;
    }
  }

  void clear() => _uaOverrides.clear();

  /// 同一 host 的验证串行执行。
  ///
  /// 并发抓 30 章时不能让用户同时面对 30 个验证窗口。
  Future<T> serialize<T>(String key, Future<T> Function() action) {
    final k = key.toLowerCase();
    final previous = _locks[k] ?? Future<void>.value();
    final gate = Completer<void>();
    final chained = gate.future;
    _locks[k] = chained;
    return previous.then((_) => action()).whenComplete(() {
      if (!gate.isCompleted) gate.complete();
      if (identical(_locks[k], chained)) _locks.remove(k);
    });
  }
}

/// 检测 + 委托宿主 + 落盘凭证。
class CloudflareGuard {
  CloudflareGuard({
    required this.store,
    this.handler,
    ChallengeState? state,
  }) : state = state ?? ChallengeState();

  final CookieStore store;

  /// 显式指定的处理器（测试 / 宿主自建客户端时用）。
  final ChallengeHandler? handler;

  final ChallengeState state;

  /// 没有显式处理器时，**每次调用时**再看一眼宿主注册表。
  ///
  /// 不能在构造时固化：服务层的 `NetClient` 在内核 init 里就建好了，
  /// 而 App 的验证页是 `runApp` 之前才注册的 —— 固化下来就等于永远没有处理器，
  /// 现场表现是「App 里撞上 Cloudflare 直接被抛异常，验证页从来不弹」。
  ChallengeHandler? get effectiveHandler =>
      handler ?? HostVerification.challengeHandler;

  bool get canSolve => effectiveHandler != null;

  /// 请求宿主完成验证。
  ///
  /// - 没有 handler：抛 [CloudflareChallengeException]。
  /// - 宿主返回 null / [ChallengeSolution.skip]：返回 null，调用方原样返回被拦截的响应。
  /// - 成功：把 cookie 与 UA 写回，返回可用的解决方案。
  Future<ChallengeSolution?> solve(ChallengeRequest request) async {
    final h = effectiveHandler;
    if (h == null) {
      throw CloudflareChallengeException(
        request.uri,
        statusCode: request.statusCode,
        reason: request.reason,
      );
    }
    return state.serialize(request.host, () async {
      final solution = await h(request);
      if (solution == null || solution.skip) return null;
      apply(request, solution);
      return solution;
    });
  }

  /// 把宿主的验证结果落到 CookieStore / UA 覆盖表。
  ///
  /// 用的是「合并」写入而不是整份替换：验证只新增 `cf_clearance`，
  /// 用户原有的登录态 cookie 必须保留——整份覆盖会把人踢下线。
  void apply(ChallengeRequest request, ChallengeSolution solution) {
    final cookie = solution.cookie;
    if (cookie != null && cookie.trim().isNotEmpty) {
      store.importCookieHeader(request.uri, cookie);
    }
    final ua = solution.userAgent;
    if (ua != null && ua.isNotEmpty) {
      state.setUserAgent(request.host, ua);
    }
  }
}
