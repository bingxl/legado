/// 网络层的唯一入口。
///
/// 上层（规则引擎 / 服务层 / CLI）只该 import 这个文件，不要直接 import
/// `http_client.dart` 之类的实现细节——那会把「换底层实现」的自由度丢掉。
///
/// ```dart
/// final net = NetClient(onChallenge: (req) => webview.solve(req));
/// await net.loadCookies('$home/cookies.json');
/// final resp = await net.get(Uri.parse('https://example.com/'));
/// print(resp.text());
/// await net.saveCookies('$home/cookies.json');
/// ```
library;

import 'dart:convert';

import 'charset.dart' as charset_utils;
import 'cloudflare.dart';
import 'cookie_store.dart';
import 'http_client.dart';
import 'rate_limiter.dart';

export 'charset.dart';
export 'cloudflare.dart';
export 'cookie_store.dart'
    show Cookie, CookieStore, parseCookieDate, parseSetCookie;
export 'downloader.dart';
export 'http_client.dart'
    show
        HttpRequest,
        HttpResponse,
        HttpStreamResponse,
        LegadoHttpClient,
        kDefaultUserAgent,
        mergeCookieHeaders,
        parseContentRangeStart,
        parseContentRangeTotal,
        sanitizeUri,
        splitSetCookieHeader;
export 'rate_limiter.dart';
export 'source_rate_gate.dart';

/// 面向业务的门面：把 cookie / 限流 / 反爬 / 编码几件事组装好。
///
/// 一个进程建一个实例即可；[withHeaders] 派生出来的实例共享 cookie、限流配额
/// 与连接池，用来叠加书源自带的请求头。
class NetClient {
  NetClient({
    CookieStore? cookieStore,
    RateLimiter? limiter,
    ChallengeHandler? onChallenge,
    ChallengeState? challengeState,
    bool useSystemProxy = false,
    Duration timeout = const Duration(seconds: 60),
    Map<String, String>? defaultHeaders,
    bool logging = false,
    int maxRetries = 2,
    int maxRedirects = 5,
  }) : this._(
         LegadoHttpClient(
           cookieStore: cookieStore,
           limiter: limiter,
           onChallenge: onChallenge,
           challengeState: challengeState,
           useSystemProxy: useSystemProxy,
           timeout: timeout,
           defaultHeaders: defaultHeaders,
           logging: logging,
           maxRetries: maxRetries,
           maxRedirects: maxRedirects,
         ),
         ownsClient: true,
       );

  NetClient._(this._client, {required bool ownsClient})
    : _ownsClient = ownsClient;

  /// 用一个现成的底层客户端构造（测试 / 自定义 transport 用）。
  factory NetClient.withHttpClient(
    LegadoHttpClient client, {
    bool ownsClient = false,
  }) => NetClient._(client, ownsClient: ownsClient);

  final LegadoHttpClient _client;
  final bool _ownsClient;

  /// cookie 容器，宿主可以直接读写（导入 WebView cookie、清登录态）。
  CookieStore get cookies => _client.store;

  /// 限流器，宿主可调 `resetHost` 解除退避。
  RateLimiter get limiter => _client.limiter;

  /// 反爬守卫，宿主可读 UA 覆盖表。
  CloudflareGuard get guard => _client.guard;

  /// 底层客户端（需要发非常规请求时用）。
  LegadoHttpClient get http => _client;

  /// GET。
  Future<HttpResponse> get(
    Uri uri, {
    Map<String, String>? headers,
    String? charset,
    Duration? timeout,
  }) {
    return _client.send(
      HttpRequest(
        uri,
        method: 'GET',
        headers: _merge(headers),
        charset: charset,
        timeout: timeout,
      ),
    );
  }

  /// POST。
  ///
  /// [body] 的形态决定 Content-Type：
  /// - `Map` / `List<MapEntry>` → `application/x-www-form-urlencoded`
  /// - `String` → 看着像 JSON 就用 `application/json`，否则表单
  /// - `List<int>` / `Uint8List` → 原样发送（需自己给 Content-Type）
  /// - 其他（`List`/对象）→ `jsonEncode` 后按 JSON 发送
  ///
  /// 需要精确控制时用 [postForm] / [postJson] / [send]。
  Future<HttpResponse> post(
    Uri uri, {
    Object? body,
    Map<String, String>? headers,
    String? charset,
    Duration? timeout,
  }) {
    final prepared = _prepareBody(body, headers);
    return _client.send(
      HttpRequest(
        uri,
        method: 'POST',
        headers: prepared.headers,
        body: prepared.body,
        charset: charset,
        timeout: timeout,
      ),
    );
  }

  /// 表单 POST（`a=1&b=2`）。
  ///
  /// 用 [charset] = `gbk` 时会按 GBK 编码 body：GBK 站点把 UTF-8 的百分号编码
  /// 当 GBK 解，搜索词直接变乱码，这是老站搜索「搜不到东西」的头号原因。
  Future<HttpResponse> postForm(
    Uri uri,
    Map<String, String> form, {
    Map<String, String>? headers,
    String? charset,
    Duration? timeout,
  }) {
    final encoded = encodeForm(form, charset: charset);
    final merged = <String, String>{
      'content-type':
          'application/x-www-form-urlencoded; charset=${charset ?? 'UTF-8'}',
      ..._merge(headers),
    };
    return _client.send(
      HttpRequest(
        uri,
        method: 'POST',
        headers: merged,
        body: encoded,
        charset: charset,
        timeout: timeout,
      ),
    );
  }

  /// JSON POST。
  Future<HttpResponse> postJson(
    Uri uri,
    Object? body, {
    Map<String, String>? headers,
    String? charset,
    Duration? timeout,
  }) {
    final merged = <String, String>{
      'content-type': 'application/json; charset=UTF-8',
      ..._merge(headers),
    };
    return _client.send(
      HttpRequest(
        uri,
        method: 'POST',
        headers: merged,
        body: utf8.encode(jsonEncode(body)),
        charset: charset,
        timeout: timeout,
      ),
    );
  }

  /// 直接发一个自定义请求（会叠加 [withHeaders] 设置的默认头）。
  Future<HttpResponse> send(HttpRequest request) {
    if (_headers.isEmpty) return _client.send(request);
    return _client.send(
      request.copyWith(headers: _merge(request.headers)),
    );
  }

  /// 流式请求（下载器用），会叠加 [withHeaders] 设置的默认头。
  Future<HttpStreamResponse> sendStream(HttpRequest request) {
    if (_headers.isEmpty) return _client.sendStream(request);
    return _client.sendStream(
      request.copyWith(headers: _merge(request.headers)),
    );
  }

  /// 生成叠加了额外默认头的新实例。
  ///
  /// 书源 `header` 字段就是这么用的：不能改全局实例（并发解析多个书源会串味），
  /// 但又要共享 cookie 与限流配额。所以派生实例复用同一个底层客户端。
  NetClient withHeaders(Map<String, String> extra) {
    return NetClient._(_client, ownsClient: false)
      .._headers
          .addAll(extra.map((k, v) => MapEntry(k.toLowerCase(), v)));
  }

  /// 本实例叠加的额外头。[withHeaders] 写、[get]/[post] 读。
  final Map<String, String> _headers = {};

  Map<String, String> _merge(Map<String, String>? given) {
    if (_headers.isEmpty && (given == null || given.isEmpty)) {
      return const {};
    }
    return {..._headers, ...?given};
  }

  /// 从文件加载 cookie。
  Future<void> loadCookies(String path) => cookies.load(path);

  /// 保存 cookie 到文件。调用方决定路径（通常是 `$homeDir/cookies.json`）。
  Future<void> saveCookies(String path) => cookies.save(path);

  /// 关闭连接池与限流器。派生实例调用它不会影响原实例（共享连接池）。
  void close() {
    if (_ownsClient) _client.close();
  }

  _PreparedBody _prepareBody(Object? body, Map<String, String>? headers) {
    final merged = _merge(headers);
    if (body == null) return _PreparedBody(null, merged);
    if (body is List<int>) {
      return _PreparedBody(body, merged);
    }
    if (body is Map) {
      final form = <String, String>{
        for (final entry in body.entries) '${entry.key}': '${entry.value}',
      };
      final out = <String, String>{
        'content-type': 'application/x-www-form-urlencoded; charset=UTF-8',
        ...merged,
      };
      return _PreparedBody(encodeForm(form), out);
    }
    if (body is String) {
      final isJson = _looksLikeJson(body);
      final out = <String, String>{
        'content-type': isJson
            ? 'application/json; charset=UTF-8'
            : 'application/x-www-form-urlencoded; charset=UTF-8',
        ...merged,
      };
      return _PreparedBody(utf8.encode(body), out);
    }
    final out = <String, String>{
      'content-type': 'application/json; charset=UTF-8',
      ...merged,
    };
    return _PreparedBody(utf8.encode(jsonEncode(body)), out);
  }
}

class _PreparedBody {
  _PreparedBody(this.body, this.headers);

  final List<int>? body;
  final Map<String, String> headers;
}

/// 是否长得像 JSON（对象或数组）。
bool _looksLikeJson(String s) {
  final t = s.trim();
  if (t.length < 2) return false;
  return (t.startsWith('{') && t.endsWith('}')) ||
      (t.startsWith('[') && t.endsWith(']'));
}

/// 把 Map 编码成 `application/x-www-form-urlencoded` 的 body。
///
/// 关键是「先按目标编码取字节，再逐字节百分号转义」：
/// 直接用 `Uri.encodeQueryComponent` 只能得到 UTF-8 的 `%E4%B8%AD`，
/// GBK 站点会把它当 GBK 解成乱码，搜索直接无结果。
List<int> encodeForm(Map<String, String> form, {String? charset}) {
  final out = <int>[];
  var first = true;
  for (final entry in form.entries) {
    if (!first) out.add(0x26); // &
    first = false;
    out.addAll(percentEncode(entry.key, charset: charset));
    out.add(0x3D); // =
    out.addAll(percentEncode(entry.value, charset: charset));
  }
  return out;
}

/// 把「已经是 `a=1&b=2` 形态」的原始 body 编码成表单字节。
///
/// 书源规则里的 `{"method":"POST","body":"id=xxx"}` 给出的就是这种串，
/// 直接原样发出去有两个问题：
/// - 空格、中文等字符没有百分号转义；
/// - 老字符集站点要按 GBK 取字节。
List<int> encodeFormBody(String body, {String? charset}) {
  final out = <int>[];
  var first = true;
  for (final pair in body.split('&')) {
    if (pair.isEmpty) continue;
    if (!first) out.add(0x26); // &
    first = false;
    final eq = pair.indexOf('=');
    if (eq < 0) {
      out.addAll(percentEncode(pair, charset: charset));
    } else {
      out.addAll(percentEncode(pair.substring(0, eq), charset: charset));
      out.add(0x3D); // =
      out.addAll(percentEncode(pair.substring(eq + 1), charset: charset));
    }
  }
  return out;
}

const String _hexDigits = '0123456789ABCDEF';

/// 按 [charset] 编码后做百分号转义（空格用 `+`）。
List<int> percentEncode(String text, {String? charset}) {
  final bytes = charset_utils.encode(text, charset: charset);
  final out = <int>[];
  for (final b in bytes) {
    final unreserved =
        (b >= 0x30 && b <= 0x39) ||
        (b >= 0x41 && b <= 0x5A) ||
        (b >= 0x61 && b <= 0x7A) ||
        b == 0x2D ||
        b == 0x2E ||
        b == 0x5F ||
        b == 0x7E;
    if (unreserved) {
      out.add(b);
    } else if (b == 0x20) {
      out.add(0x2B);
    } else {
      out
        ..add(0x25) // %
        ..add(_hexDigits.codeUnitAt((b >> 4) & 0xF))
        ..add(_hexDigits.codeUnitAt(b & 0xF));
    }
  }
  return out;
}
