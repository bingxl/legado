/// 测试用的本地回环服务器。
///
/// 所有网络测试都打本机，**不出网**：CI 无外网也要能跑，且真实站点会让
/// 「限流 / 超时 / 重定向」这类断言变得不可控。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/net/rate_limiter.dart';

/// 测试用限流器：不限速。
///
/// 默认 100ms 的最小间隔会让「8 个请求」的用例凭空多等 0.8 秒，
/// 限流本身的正确性由 rate_limiter_test 单独验证。
RateLimiter testLimiter() => RateLimiter(
  perHostConcurrency: 8,
  globalConcurrency: 32,
  minInterval: Duration.zero,
);

/// 一次被记录下来的请求。
class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });

  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final List<int> body;

  /// 取请求头（多值用 `,` 连接）。
  String? header(String name) => headers.value(name);

  String get bodyText => String.fromCharCodes(body);
}

/// 回环服务器。
class TestServer {
  TestServer._(this._server);

  final HttpServer _server;

  /// 收到的请求，按到达顺序排列。
  final List<RecordedRequest> requests = [];

  int get port => _server.port;

  int get requestCount => requests.length;

  Uri get base => Uri.parse('http://127.0.0.1:$port');

  Uri uri(String path, [Map<String, String>? query]) =>
      Uri.parse('http://127.0.0.1:$port$path').replace(queryParameters: query);

  /// 最近一次请求。
  RecordedRequest get last => requests.last;

  static Future<TestServer> start(
    FutureOr<void> Function(RecordedRequest request, HttpRequest raw)
    handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final ts = TestServer._(server);
    server.listen((raw) async {
      final body = <int>[];
      await for (final chunk in raw) {
        body.addAll(chunk);
      }
      final recorded = RecordedRequest(
        method: raw.method,
        uri: raw.uri,
        headers: raw.headers,
        body: body,
      );
      ts.requests.add(recorded);
      try {
        await handler(recorded, raw);
      } catch (_) {
        // handler 里抛异常（比如客户端提前断开）不该污染测试。
        try {
          await raw.response.close();
        } catch (_) {
          // ignore
        }
      }
    });
    return ts;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}

/// 写一段 HTML 并关闭响应。
Future<void> sendHtml(
  HttpRequest raw,
  String html, {
  int status = 200,
  String contentType = 'text/html; charset=utf-8',
}) async {
  raw.response.statusCode = status;
  raw.response.headers.set('content-type', contentType);
  raw.response.add(utf8Bytes(html));
  await raw.response.close();
}

/// 写任意字节并关闭响应。
Future<void> sendBytes(
  HttpRequest raw,
  List<int> bytes, {
  int status = 200,
  Map<String, String>? headers,
}) async {
  raw.response.statusCode = status;
  headers?.forEach((k, v) => raw.response.headers.set(k, v));
  raw.response.add(bytes);
  await raw.response.close();
}

/// UTF-8 编码（避免每个测试文件都 import dart:convert）。
List<int> utf8Bytes(String s) => utf8.encode(s);
