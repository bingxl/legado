/// 纯 Dart HTTP 客户端。
///
/// 为什么不用 `dart:io HttpClient` 直接裸奔：`package:http` 的 `IOClient`
/// 帮我们处理了 stream → bytes、连接复用、请求中止这些琐事，且它本身就是
/// `dart:io` 的薄封装——没有引入任何 Flutter / 平台通道依赖，CLI 与 App 共用。
///
/// 但重定向必须自己走：`IOClient` 走的是 `dart:io` 的自动跟随，拿不到中间
/// 跳的 `Set-Cookie` 与每一跳的 URL。书源站点里「登录 → 302 到首页」这种链路，
/// 302 上带的 cookie 丢了就会表现为「登录成功但仍然是游客」。所以这里统一
/// `followRedirects = false`，手动跟，逐跳存 cookie、逐跳记录 `finalUri`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';

import 'charset.dart' as charset_utils;
import 'cloudflare.dart';
import 'cookie_store.dart';
import 'rate_limiter.dart';

/// 默认 UA：Chrome 桌面版。
///
/// 很多书源站点对非浏览器 UA 直接返回 403 或降级页面；用桌面 UA 最稳。
/// 可以被请求头或 Cloudflare 验证后的 UA 覆盖。
const String kDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

/// 默认 Accept。
const String kDefaultAccept =
    'text/html,application/xhtml+xml,application/xml;q=0.9,'
    'image/avif,image/webp,*/*;q=0.8';

const String kDefaultAcceptLanguage = 'zh-CN,zh;q=0.9,en;q=0.8';

/// 日志脱敏时会被替换掉值的 query 参数名。
const Set<String> kSensitiveQueryKeys = {
  'token',
  'key',
  'apikey',
  'api_key',
  'password',
  'passwd',
  'pwd',
  'sign',
  'signature',
  'secret',
  'access_token',
  'auth',
  'session',
  'sessionid',
  'ticket',
};

final Logger _log = Logger('legado.net');

/// 把 URL 的敏感 query 参数值替换成 `***`，供日志使用。
///
/// 书源里有大量 `?token=xxx&sign=yyy` 形式的接口，整条打印出来等于把用户的
/// 付费账号贴到日志文件里，再被打包发给开发者。
Uri sanitizeUri(Uri uri) {
  if (uri.query.isEmpty) return uri;
  final parts = uri.query.split('&');
  var changed = false;
  final out = <String>[];
  for (final part in parts) {
    final eq = part.indexOf('=');
    if (eq <= 0) {
      out.add(part);
      continue;
    }
    final key = part.substring(0, eq);
    if (kSensitiveQueryKeys.contains(key.toLowerCase())) {
      out.add('$key=***');
      changed = true;
    } else {
      out.add(part);
    }
  }
  if (!changed) return uri;
  return uri.replace(query: out.join('&'));
}

/// 一个 HTTP 请求。
class HttpRequest {
  HttpRequest(
    this.uri, {
    this.method = 'GET',
    Map<String, String>? headers,
    this.body,
    this.timeout,
    this.charset,
    this.label = '',
    this.promptOnChallenge = true,
  }) : headers = headers == null
           ? <String, String>{}
           : Map<String, String>.of(headers);

  /// 目标地址。
  final Uri uri;

  /// 方法，自动大写。
  final String method;

  /// 请求头（会被默认头与 cookie 补齐，但这里的值优先）。
  final Map<String, String> headers;

  /// 请求体原始字节。
  final List<int>? body;

  /// 本次请求的超时；null 表示用客户端默认值。
  final Duration? timeout;

  /// 强制使用的响应编码（对齐原版 `ResponseBody.text(encode)`）。
  final String? charset;

  /// 发起方标识（书源名 / 订阅名）。
  ///
  /// 只用于反爬验证窗口的标题：用户同时验证多个站点时，窗口上写「书源名」
  /// 才能分清哪个是哪个。网络层不参与语义判断。
  final String label;

  /// 撞上反爬挑战时是否允许拉起内置浏览器。
  ///
  /// 默认 true。**验证通过后重新取正文的那一次必须置 false**：
  /// 凭证若仍不生效，允许弹窗就会「弹窗 → 重抓 → 又是挑战 → 再弹窗」，
  /// 用户永远关不掉（原版用 `AnalyzeUrl.NoChallenge` 挡的同一件事）。
  final bool promptOnChallenge;

  /// 是否为表单/JSON 等带 body 的请求。
  bool get hasBody => body != null && body!.isNotEmpty;

  /// 便于打日志的脱敏 URL。
  String get safeUri => sanitizeUri(uri).toString();

  HttpRequest copyWith({
    Uri? uri,
    String? method,
    Map<String, String>? headers,
    List<int>? body,
    Duration? timeout,
    String? charset,
    String? label,
    bool? promptOnChallenge,
  }) {
    return HttpRequest(
      uri ?? this.uri,
      method: method ?? this.method,
      headers: headers ?? this.headers,
      body: body ?? this.body,
      timeout: timeout ?? this.timeout,
      charset: charset ?? this.charset,
      label: label ?? this.label,
      promptOnChallenge: promptOnChallenge ?? this.promptOnChallenge,
    );
  }
}

/// 一个 HTTP 响应。
class HttpResponse {
  HttpResponse({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
    required this.finalUri,
    this.charsetHint,
    this.elapsed,
  });

  /// HTTP 状态码。
  final int statusCode;

  /// 响应头，key 一律小写，value 保留多值（`Set-Cookie` 靠这个）。
  final Map<String, List<String>> headers;

  /// 原始响应体字节（已解压）。
  final List<int> bodyBytes;

  /// 跟随重定向之后的最终地址。
  final Uri finalUri;

  /// 请求里显式指定的编码，优先级最高。
  final String? charsetHint;

  /// 本次请求耗时（含重试）。
  final Duration? elapsed;

  final Map<String, String> _textCache = {};

  /// 是否 2xx。
  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// 是否 3xx。
  bool get isRedirect =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  /// 取单个响应头（忽略大小写，多值用 `, ` 连接）。
  String? header(String name) => headerValue(headers, name);

  /// Content-Type 原文。
  String? get contentType => header('content-type');

  /// 文本长度。
  int get length => bodyBytes.length;

  /// 解码为字符串。
  ///
  /// 优先级：显式 [charset] > 请求里指定的 `charset` > 响应头 Content-Type >
  /// BOM / meta / 启发式。结果按「拿到的 charset」缓存，避免重复解码大正文。
  String text([String? charset]) {
    final cs = charset ?? charsetHint ?? '';
    final cached = _textCache[cs];
    if (cached != null) return cached;
    final decoded = charset_utils.decode(
      bodyBytes,
      declaredCharset: charset ?? charsetHint,
      contentType: contentType,
    );
    _textCache[cs] = decoded;
    return decoded;
  }

  /// 按 JSON 解码。失败抛 [FormatException]。
  dynamic json() {
    var text = this.text().trim();
    if (text.isEmpty) return null;
    // 有些接口会加 XSSI 前缀，直接 jsonDecode 会炸。
    if (text.startsWith('while(1);')) {
      text = text.substring(9).trim();
    }
    return jsonDecode(text);
  }

  @override
  String toString() =>
      'HttpResponse($statusCode, ${bodyBytes.length} bytes, $finalUri)';
}

/// 内部：缓冲模式下一跳的结果。
class _RawResponse {
  _RawResponse(this.statusCode, this.headers, this.bodyBytes);

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;
}

/// 流式响应：响应头已到，正文按块消费。
///
/// 给下载器用：整本书的图片包可能有几百 MB，不能先 `toBytes()` 再写。
class HttpStreamResponse {
  HttpStreamResponse({
    required this.statusCode,
    required this.headers,
    required this.finalUri,
    required this.bytes,
  });

  final int statusCode;
  final Map<String, List<String>> headers;

  /// 跟随重定向后的最终地址。
  final Uri finalUri;

  /// 正文字节流。调用方**必须**消费完或取消订阅，否则连接不会回收。
  final Stream<List<int>> bytes;

  String? header(String name) => headerValue(headers, name);

  /// Content-Length（可能是剩余长度，206 时尤其要注意）。
  int? get contentLength {
    final raw = header('content-length');
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }

  /// 解析 `Content-Range: bytes 100-199/200` 里的总长度。
  int? get contentRangeTotal => parseContentRangeTotal(header('content-range'));

  @override
  String toString() => 'HttpStreamResponse($statusCode, $finalUri)';
}

/// 解析 `Content-Range` 的总长度。
///
/// `bytes 100-199/200` → 200；`bytes 100-199/*` → null（总长未知）。
int? parseContentRangeTotal(String? value) {
  if (value == null || value.isEmpty) return null;
  final slash = value.lastIndexOf('/');
  if (slash < 0 || slash == value.length - 1) return null;
  final total = value.substring(slash + 1).trim();
  if (total == '*') return null;
  return int.tryParse(total);
}

/// 解析 `Content-Range: bytes 100-199/200` 的起始偏移。
int? parseContentRangeStart(String? value) {
  if (value == null || value.isEmpty) return null;
  final m = RegExp(r'bytes\s+(\d+)-').firstMatch(value);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 带 cookie / 限流 / 反爬 / 重试的 HTTP 客户端。
class LegadoHttpClient {
  LegadoHttpClient({
    CookieStore? cookieStore,
    RateLimiter? limiter,
    ChallengeHandler? onChallenge,
    ChallengeState? challengeState,
    bool useSystemProxy = false,
    this.timeout = const Duration(seconds: 60),
    Map<String, String>? defaultHeaders,
    this.logging = false,
    this.maxRetries = 2,
    this.maxRedirects = 5,
    http.Client? client,
    bool ownsClient = true,
  }) : store = cookieStore ?? CookieStore(),
       limiter = limiter ?? RateLimiter(),
       _defaultHeaders = {
         'user-agent': kDefaultUserAgent,
         'accept': kDefaultAccept,
         'accept-language': kDefaultAcceptLanguage,
         ...?defaultHeaders?.map((k, v) => MapEntry(k.toLowerCase(), v)),
       },
       _ownsClient = client == null && ownsClient,
       _client = client ?? _createClient(useSystemProxy) {
    guard = CloudflareGuard(
      store: store,
      // 显式处理器优先；没有时由 guard 在每次调用时去宿主注册表取
      // （见 CloudflareGuard.effectiveHandler —— 注册时机晚于构造）。
      handler: onChallenge,
      state: challengeState,
    );
  }

  /// cookie 容器（跨请求共享，登录态就靠它）。
  final CookieStore store;

  /// 限流器。
  final RateLimiter limiter;

  /// 默认超时。
  final Duration timeout;

  /// 连接层失败的重试次数（不含 Cloudflare 验证重试）。
  final int maxRetries;

  /// 最多跟随多少次重定向。
  final int maxRedirects;

  /// 是否打印请求/响应日志。
  final bool logging;

  /// 反爬守卫。
  late final CloudflareGuard guard;

  final Map<String, String> _defaultHeaders;
  final http.Client _client;
  final bool _ownsClient;

  bool _closed = false;

  /// 关闭底层连接池。
  ///
  /// 只有「自己创建了 http.Client」的实例才真正关：`withHeaders` 派生出来的
  /// 实例共享同一个连接池，关掉会把原实例一起弄死。
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) {
      _client.close();
    }
    limiter.close();
  }

  /// 发一个请求（含重试、重定向、cookie、反爬）。
  Future<HttpResponse> send(HttpRequest request) async {
    if (_closed) throw StateError('LegadoHttpClient 已关闭');
    final sw = Stopwatch()..start();
    final effectiveTimeout = request.timeout ?? timeout;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        // 指数退避：150ms、300ms。太短没意义，太长用户会以为卡死。
        await Future<void>.delayed(
          Duration(milliseconds: 150 * (1 << (attempt - 1))),
        );
      }
      try {
        final resp = await _sendOnce(request, effectiveTimeout);
        return HttpResponse(
          statusCode: resp.statusCode,
          headers: resp.headers,
          bodyBytes: resp.bodyBytes,
          finalUri: resp.finalUri,
          charsetHint: request.charset,
          elapsed: sw.elapsed,
        );
      } on CloudflareChallengeException {
        // 反爬拦截是「明确的业务结果」，不该被当成网络故障重试。
        rethrow;
      } on TimeoutException catch (e, s) {
        lastError = e;
        lastStack = s;
      } on SocketException catch (e, s) {
        lastError = e;
        lastStack = s;
      } on http.ClientException catch (e, s) {
        lastError = e;
        lastStack = s;
      } on HandshakeException catch (e, s) {
        lastError = e;
        lastStack = s;
      }
      if (logging) {
        _log.warning(
          '请求失败（第 ${attempt + 1}/${maxRetries + 1} 次）：'
          '${request.method} ${request.safeUri} → $lastError',
        );
      }
    }
    Error.throwWithStackTrace(
      lastError ?? StateError('请求失败：${request.safeUri}'),
      lastStack ?? StackTrace.current,
    );
  }

  // ---------------------------------------------------------------------------

  /// 流式请求：拿到响应头和未读完的字节流，供下载器按块落盘。
  ///
  /// 与 [send] 的差异（都是刻意的）：
  /// - **不重试**：字节已经开始消费了，重试语义由调用方（下载器）决定。
  /// - **不解压**：下载的是图片/压缩包，解压会破坏字节且让 Content-Length 对不上。
  /// - **不做 Cloudflare 人工验证**：二进制下载没法把渲染结果当正文，
  ///   命中时直接抛 [CloudflareChallengeException]。
  ///
  /// 重定向、cookie、限流与原 [send] 共用同一套逻辑。
  Future<HttpStreamResponse> sendStream(HttpRequest request) async {
    if (_closed) throw StateError('LegadoHttpClient 已关闭');
    var uri = request.uri;
    var redirects = 0;
    final timeout = request.timeout ?? this.timeout;

    while (true) {
      final prepared = _buildHeaders(uri, request.headers);
      if (logging) {
        _log.fine('→(stream) ${request.method} ${sanitizeUri(uri)}');
      }
      final streamed = await _open(
        uri: uri,
        method: request.method.toUpperCase(),
        headers: prepared,
        body: request.body,
        timeout: timeout,
      );
      final headers = _collectHeaders(streamed.headers);

      final setCookies = headers['set-cookie'];
      if (setCookies != null && setCookies.isNotEmpty) {
        store.setFromResponse(uri, setCookies);
      }

      if (streamed.statusCode >= 300 && streamed.statusCode < 400) {
        final location = headerValue(headers, 'location');
        if (location != null && location.isNotEmpty) {
          // 必须把跳转响应的 body 读干净，否则连接池里会留一条脏连接。
          await streamed.stream.drain<void>();
          if (redirects >= maxRedirects) {
            return HttpStreamResponse(
              statusCode: streamed.statusCode,
              headers: headers,
              finalUri: uri,
              bytes: const Stream<List<int>>.empty(),
            );
          }
          final next = _resolveLocation(uri, location);
          if (next == null) {
            return HttpStreamResponse(
              statusCode: streamed.statusCode,
              headers: headers,
              finalUri: uri,
              bytes: const Stream<List<int>>.empty(),
            );
          }
          redirects++;
          uri = next;
          continue;
        }
      }

      final reason = cloudflareChallengeReason(streamed.statusCode, headers);
      if (reason != null) {
        await streamed.stream.drain<void>();
        throw CloudflareChallengeException(
          uri,
          statusCode: streamed.statusCode,
          reason: reason,
        );
      }

      return HttpStreamResponse(
        statusCode: streamed.statusCode,
        headers: headers,
        finalUri: uri,
        bytes: streamed.stream,
      );
    }
  }

  Future<_Resolved> _sendOnce(HttpRequest request, Duration effectiveTimeout) async {
    var uri = request.uri;
    var method = request.method.toUpperCase();
    var body = request.body;
    var redirects = 0;
    var challengeTried = false;
    String? pendingChallengeBody;

    while (true) {
      final prepared = _buildHeaders(uri, request.headers);
      if (logging) {
        _log.fine(
          '→ $method ${sanitizeUri(uri)} '
          '(cookie=${prepared.containsKey('cookie') ? 'yes' : 'no'})',
        );
      }

      final raw = await _perform(
        uri: uri,
        method: method,
        headers: prepared,
        body: body,
        timeout: effectiveTimeout,
      );

      // cookie 逐跳落地：302 上带的 Set-Cookie 不能丢。
      final setCookies = raw.headers['set-cookie'];
      if (setCookies != null && setCookies.isNotEmpty) {
        store.setFromResponse(uri, setCookies);
      }

      if (logging) {
        _log.fine(
          '← ${raw.statusCode} ${sanitizeUri(uri)} '
          '(${raw.bodyBytes.length} bytes)',
        );
      }

      // ---- 重定向 ----
      if (raw.statusCode >= 300 && raw.statusCode < 400) {
        final location = headerValue(raw.headers, 'location');
        if (location != null && location.isNotEmpty) {
          if (redirects >= maxRedirects) {
            if (logging) {
              _log.warning('重定向次数超过 $maxRedirects：${request.safeUri}');
            }
            return _Resolved(raw.statusCode, raw.headers, raw.bodyBytes, uri);
          }
          redirects++;
          final next = _resolveLocation(uri, location);
          if (next == null) {
            return _Resolved(raw.statusCode, raw.headers, raw.bodyBytes, uri);
          }
          // 303 一律转 GET；301/302 对 POST 降级为 GET（浏览器行为）。
          if ((raw.statusCode == 303 ||
                  (raw.statusCode == 301 || raw.statusCode == 302)) &&
              method != 'GET' &&
              method != 'HEAD') {
            method = 'GET';
            body = null;
          }
          uri = next;
          continue;
        }
      }

      // ---- Cloudflare ----
      final reason = cloudflareChallengeReason(raw.statusCode, raw.headers);
      if (reason != null && !challengeTried) {
        if (!guard.canSolve || !request.promptOnChallenge) {
          throw CloudflareChallengeException(
            uri,
            statusCode: raw.statusCode,
            reason: reason,
          );
        }
        final solution = await guard.solve(
          ChallengeRequest(
            uri: uri,
            statusCode: raw.statusCode,
            reason: reason,
            headers: prepared,
            label: request.label,
          ),
        );
        challengeTried = true;
        if (solution != null) {
          final cookie = solution.cookie?.trim() ?? '';
          final pageBody = solution.body;
          if (pageBody != null && pageBody.isNotEmpty) {
            pendingChallengeBody = pageBody;
          }
          if (cookie.isEmpty) {
            // 宿主没拿到 cf_clearance：重试必然还是挑战页，直接用渲染结果。
            if (pendingChallengeBody != null) {
              return _fromText(uri, pendingChallengeBody);
            }
            return _Resolved(raw.statusCode, raw.headers, raw.bodyBytes, uri);
          }
          if (logging) {
            _log.info('反爬验证完成，带新凭证重试一次：${sanitizeUri(uri)}');
          }
          continue;
        }
        return _Resolved(raw.statusCode, raw.headers, raw.bodyBytes, uri);
      }

      // 验证过的站点有时凭证仍不生效（绑定 IP / 只有 __cf_bm），
      // 此时用宿主回填的渲染结果兜底，而不是把挑战页当正文返回。
      if (reason != null && pendingChallengeBody != null) {
        return _fromText(uri, pendingChallengeBody);
      }

      return _Resolved(raw.statusCode, raw.headers, raw.bodyBytes, uri);
    }
  }

  /// 真正发一跳。
  Future<_RawResponse> _perform({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int>? body,
    required Duration timeout,
  }) {
    return limiter.run(uri.host, () async {
      final streamed = await _open(
        uri: uri,
        method: method,
        headers: headers,
        body: body,
        timeout: timeout,
      );
      final bytes = await streamed.stream.toBytes().timeout(timeout);
      final collected = _collectHeaders(streamed.headers);
      return _RawResponse(
        streamed.statusCode,
        collected,
        _decompress(bytes, collected),
      );
    });
  }

  /// 打开一跳请求，返回未读的响应。
  ///
  /// 重定向必须自己处理（`followRedirects = false`），原因见文件头。
  Future<http.StreamedResponse> _open({
    required Uri uri,
    required String method,
    required Map<String, String> headers,
    required List<int>? body,
    required Duration timeout,
  }) async {
    final req = http.Request(method, uri)
      ..followRedirects = false
      ..maxRedirects = 0;
    req.headers.addAll(headers);
    if (body != null && body.isNotEmpty && method != 'GET' && method != 'HEAD') {
      req.bodyBytes = body;
    }
    return _client.send(req).timeout(timeout);
  }

  Map<String, List<String>> _collectHeaders(Map<String, String> raw) {
    final out = <String, List<String>>{};
    raw.forEach((key, value) {
      final k = key.toLowerCase();
      if (k == 'set-cookie') {
        out[k] = splitSetCookieHeader(value);
      } else {
        out[k] = [value];
      }
    });
    return out;
  }

  /// 解压响应体。
  ///
  /// `dart:io` 在我们没有手动设置 `Accept-Encoding` 时会自己加 gzip 并自动解压，
  /// 此时 body 不再有 gzip 魔数；只有「书源自己塞了 Accept-Encoding」的场景才会
  /// 拿到未解压的字节。用魔数判定可以两种情况都覆盖，且不会二次解压。
  ///
  /// brotli 没有纯 Dart 实现，见 `_buildHeaders` 里对 `br` 的剔除。
  List<int> _decompress(List<int> bytes, Map<String, List<String>> headers) {
    if (bytes.length < 2) return bytes;
    final encoding = headerValue(headers, 'content-encoding')?.toLowerCase() ?? '';
    if (encoding.isEmpty) return bytes;
    try {
      if (bytes[0] == 0x1F && bytes[1] == 0x8B) {
        return gzip.decode(bytes);
      }
      // zlib 包装的 deflate 首字节恒为 0x78（78 01/9C/DA）。
      if (encoding.contains('deflate') && bytes[0] == 0x78) {
        return zlib.decode(bytes);
      }
    } catch (e) {
      if (logging) {
        _log.warning('解压失败（$encoding），按原始字节返回：$e');
      }
    }
    return bytes;
  }

  Map<String, String> _buildHeaders(Uri uri, Map<String, String> given) {
    final out = <String, String>{..._defaultHeaders};
    for (final entry in given.entries) {
      out[entry.key.toLowerCase()] = entry.value;
    }

    // UA 覆盖：验证过的域名一律用浏览器的 UA，书源配的 UA 让位。
    final overridden = guard.state.userAgentFor(uri.host);
    if (overridden != null && overridden.isNotEmpty) {
      out['user-agent'] = overridden;
    }

    // Referer 默认给站点根：防盗链站点没有它直接 403。
    if (!out.containsKey('referer')) {
      out['referer'] = '${uri.scheme}://${uri.authority}/';
    }

    // brotli 解不了，主动剔掉，免得服务端回一段我们无法处理的字节。
    final ae = out['accept-encoding'];
    if (ae != null) {
      final kept = ae
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.toLowerCase().startsWith('br'))
          .join(', ');
      if (kept.isEmpty) {
        out.remove('accept-encoding');
      } else {
        out['accept-encoding'] = kept;
      }
    }

    // cookie：请求头里手写的优先，其余从 store 补齐。
    final stored = store.getCookieHeader(uri);
    final explicit = out['cookie'];
    if (stored != null && stored.isNotEmpty) {
      out['cookie'] = explicit == null || explicit.trim().isEmpty
          ? stored
          : mergeCookieHeaders(explicit, stored);
    }
    return out;
  }

  static http.Client _createClient(bool useSystemProxy) {
    final io = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    if (useSystemProxy) {
      final httpProxy = _envProxy('HTTP_PROXY', 'http_proxy');
      final httpsProxy = _envProxy('HTTPS_PROXY', 'https_proxy');
      if (httpProxy != null || httpsProxy != null) {
        io.findProxy = (uri) {
          final raw = uri.scheme == 'https'
              ? (httpsProxy ?? httpProxy)
              : (httpProxy ?? httpsProxy);
          return _toFindProxy(raw);
        };
      }
    }
    return IOClient(io);
  }

  static String? _envProxy(String upper, String lower) {
    final v = Platform.environment[upper] ?? Platform.environment[lower];
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  /// `http://127.0.0.1:7890` → `PROXY 127.0.0.1:7890`。
  static String _toFindProxy(String? raw) {
    if (raw == null || raw.isEmpty) return 'DIRECT';
    var s = raw;
    final schemeIdx = s.indexOf('://');
    if (schemeIdx >= 0) s = s.substring(schemeIdx + 3);
    s = s.replaceAll(RegExp(r'/+$'), '');
    final at = s.lastIndexOf('@');
    if (at >= 0) s = s.substring(at + 1);
    if (s.isEmpty) return 'DIRECT';
    return 'PROXY $s';
  }

  static _Resolved _fromText(Uri uri, String text) {
    final bytes = utf8.encode(text);
    return _Resolved(200, const {'content-type': ['text/html; charset=utf-8']}, bytes, uri);
  }
}

/// 内部：一跳或最终结果的统一形态。
class _Resolved {
  _Resolved(this.statusCode, this.headers, this.bodyBytes, this.finalUri);

  final int statusCode;
  final Map<String, List<String>> headers;
  final List<int> bodyBytes;
  final Uri finalUri;
}

/// 解析 3xx 的 Location（可能相对）。
Uri? _resolveLocation(Uri base, String location) {
  final trimmed = location.trim();
  if (trimmed.isEmpty) return null;
  try {
    final parsed = Uri.parse(trimmed);
    if (parsed.hasScheme) return parsed;
    // Uri.resolve 对 `//host/path` 与绝对路径都处理正确。
    return base.resolveUri(parsed);
  } catch (_) {
    return null;
  }
}

/// 合并两段 `a=1; b=2` 形式的 cookie 头，前面的优先。
String mergeCookieHeaders(String first, String second) {
  final seen = <String>{};
  final pairs = <String>[];
  for (final source in [first, second]) {
    for (final part in source.split(';')) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final eq = p.indexOf('=');
      final key = eq < 0 ? p : p.substring(0, eq).trim();
      if (key.isEmpty) continue;
      if (!seen.add(key)) continue;
      pairs.add(p);
    }
  }
  return pairs.join('; ');
}

/// 拆分被 `package:http` 合并成一行（`a=1, b=2`）的 Set-Cookie。
///
/// `dart:io` 的 `HttpHeaders` 本身是多值的，但 `IOClient` 会把多值 join 成
/// `', '`，且不暴露原始响应。只能靠「逗号后紧跟 `name=`」来切：
///
/// - `Expires=Wed, 21 Oct 2015 07:28:00 GMT`：逗号后是 ` 21 Oct ...`，
///   不是 `name=`，不切——这正是这条规则存在的唯一原因。
/// - `a=1, b=2`：逗号后是 ` b=`，切。
///
/// 值里真的带 `, x=1` 的畸形 cookie 会被误切，但那种 cookie 浏览器本身也不认。
List<String> splitSetCookieHeader(String joined) {
  if (joined.isEmpty) return const [];
  final out = <String>[];
  final splitter = RegExp(r",(?=\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)");
  var start = 0;
  for (final m in splitter.allMatches(joined)) {
    final piece = joined.substring(start, m.start).trim();
    if (piece.isNotEmpty) out.add(piece);
    start = m.end;
  }
  final tail = joined.substring(start).trim();
  if (tail.isNotEmpty) out.add(tail);
  return out;
}
