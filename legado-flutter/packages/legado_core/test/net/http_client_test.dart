import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/net/net.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestServer server;
  late NetClient net;

  tearDown(() async {
    net.close();
    await server.close();
  });

  NetClient newClient({
    Map<String, String>? headers,
    int maxRetries = 0,
    int maxRedirects = 5,
    Duration timeout = const Duration(seconds: 5),
  }) {
    return NetClient(
      defaultHeaders: headers,
      maxRetries: maxRetries,
      maxRedirects: maxRedirects,
      timeout: timeout,
      limiter: testLimiter(),
    );
  }

  /// 每个测试都用「没有最小间隔」的限流器，避免 100ms × N 把测试拖到分钟级。
  group('GET 基础', () {
    test('返回状态码与正文', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'hello'));
      net = newClient();
      final resp = await net.get(server.uri('/a'));
      expect(resp.statusCode, 200);
      expect(resp.text(), 'hello');
      expect(resp.finalUri.path, '/a');
      expect(resp.isSuccess, isTrue);
    });

    test('默认 UA 是桌面 Chrome', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.get(server.uri('/a'));
      expect(server.last.header('user-agent'), kDefaultUserAgent);
      expect(server.last.header('user-agent'), contains('Chrome'));
    });

    test('请求头里的 UA 覆盖默认值', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.get(
        server.uri('/a'),
        headers: {'User-Agent': 'MyReader/1.0'},
      );
      expect(server.last.header('user-agent'), 'MyReader/1.0');
    });

    test('默认带站点 Referer', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.get(server.uri('/a'));
      expect(server.last.header('referer'), 'http://127.0.0.1:${server.port}/');
    });

    test('自定义头原样透传', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.get(server.uri('/a'), headers: {'X-Token': 'abc'});
      expect(server.last.header('x-token'), 'abc');
    });

    test('非 2xx 不抛异常', () async {
      server = await TestServer.start(
        (req, raw) => sendHtml(raw, 'nope', status: 404),
      );
      net = newClient();
      final resp = await net.get(server.uri('/missing'));
      expect(resp.statusCode, 404);
      expect(resp.isSuccess, isFalse);
    });

    test('withHeaders 叠加默认头', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      final derived = net.withHeaders({'x-source': 'biquge'});
      await derived.get(server.uri('/a'));
      expect(server.last.header('x-source'), 'biquge');
      derived.close();
    });
  });

  group('cookie 收发', () {
    test('响应 Set-Cookie 落库并在下次请求带上', () async {
      server = await TestServer.start((req, raw) {
        if (req.uri.path == '/login') {
          raw.response.headers.add('set-cookie', 'sid=abc; Path=/');
          return sendHtml(raw, 'logged in');
        }
        return sendHtml(raw, 'cookie=${req.header('cookie')}');
      });
      net = newClient();
      await net.get(server.uri('/login'));
      expect(net.cookies.getCookieHeader(server.base), 'sid=abc');
      final resp = await net.get(server.uri('/me'));
      expect(resp.text(), 'cookie=sid=abc');
    });

    test('多条 Set-Cookie（Expires 带逗号）都能保留', () async {
      server = await TestServer.start((req, raw) {
        raw.response.headers
          ..add('set-cookie', 'a=1; Path=/; Expires=Wed, 21 Oct 2037 07:28:00 GMT')
          ..add('set-cookie', 'b=2; Path=/; HttpOnly');
        return sendHtml(raw, 'ok');
      });
      net = newClient();
      await net.get(server.uri('/'));
      final header = net.cookies.getCookieHeader(server.base);
      expect(header, contains('a=1'));
      expect(header, contains('b=2'));
      expect(net.cookies.length, 2);
    });

    test('重定向中间的 Set-Cookie 不丢（登录链路）', () async {
      server = await TestServer.start((req, raw) async {
        if (req.uri.path == '/login') {
          raw.response.statusCode = 302;
          raw.response.headers
            ..add('set-cookie', 'sess=xyz; Path=/')
            ..set('location', '/home');
          await raw.response.close();
          return;
        }
        await sendHtml(raw, 'cookie=${req.header('cookie')}');
      });
      net = newClient();
      final resp = await net.get(server.uri('/login'));
      expect(resp.statusCode, 200);
      expect(resp.text(), 'cookie=sess=xyz');
    });

    test('请求头里的 Cookie 与容器合并', () async {
      server = await TestServer.start((req, raw) {
        if (req.uri.path == '/set') {
          raw.response.headers.add('set-cookie', 'a=1; Path=/');
          return sendHtml(raw, 'ok');
        }
        return sendHtml(raw, 'cookie=${req.header('cookie')}');
      });
      net = newClient();
      await net.get(server.uri('/set'));
      final resp = await net.get(
        server.uri('/x'),
        headers: {'Cookie': 'b=2'},
      );
      expect(resp.text(), contains('b=2'));
      expect(resp.text(), contains('a=1'));
    });
  });

  group('重定向', () {
    test('跟随 302 且 finalUri 是最终地址', () async {
      server = await TestServer.start((req, raw) async {
        if (req.uri.path == '/a') {
          raw.response.statusCode = 302;
          raw.response.headers.set('location', '/b');
          await raw.response.close();
          return;
        }
        await sendHtml(raw, 'page-b');
      });
      net = newClient();
      final resp = await net.get(server.uri('/a'));
      expect(resp.text(), 'page-b');
      expect(resp.finalUri.path, '/b');
      expect(server.requestCount, 2);
    });

    test('超过 maxRedirects 时停在 3xx', () async {
      server = await TestServer.start((req, raw) async {
        raw.response.statusCode = 302;
        raw.response.headers.set('location', '/loop');
        await raw.response.close();
      });
      net = newClient(maxRedirects: 2);
      final resp = await net.get(server.uri('/loop'));
      expect(resp.statusCode, 302);
      // 1 次原始 + 2 次跟随
      expect(server.requestCount, 3);
    });

    test('303 把 POST 降级成 GET 且丢掉 body', () async {
      server = await TestServer.start((req, raw) async {
        if (req.uri.path == '/submit') {
          raw.response.statusCode = 303;
          raw.response.headers.set('location', '/done');
          await raw.response.close();
          return;
        }
        await sendHtml(raw, 'done');
      });
      net = newClient();
      final resp = await net.postForm(server.uri('/submit'), {'a': '1'});
      expect(resp.text(), 'done');
      expect(server.requests[1].method, 'GET');
      expect(server.requests[1].body, isEmpty);
    });

    test('相对 Location 能正确解析', () async {
      server = await TestServer.start((req, raw) async {
        if (req.uri.path == '/dir/a') {
          raw.response.statusCode = 302;
          raw.response.headers.set('location', 'b?x=1');
          await raw.response.close();
          return;
        }
        await sendHtml(raw, req.uri.toString());
      });
      net = newClient();
      final resp = await net.get(server.uri('/dir/a'));
      expect(resp.finalUri.path, '/dir/b');
      expect(resp.finalUri.query, 'x=1');
    });
  });

  group('POST', () {
    test('form 编码正确', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, req.bodyText));
      net = newClient();
      final resp = await net.postForm(server.uri('/f'), {
        'kw': '中文',
        'page': '2',
      });
      expect(resp.text(), contains('kw=%E4%B8%AD%E6%96%87'));
      expect(resp.text(), contains('page=2'));
      expect(
        server.last.header('content-type'),
        contains('application/x-www-form-urlencoded'),
      );
    });

    test('GBK 站点的 form 按 GBK 编码', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.postForm(server.uri('/f'), {'kw': '中文'}, charset: 'gbk');
      expect(server.last.bodyText, 'kw=%D6%D0%CE%C4');
    });

    test('postJson 设置 content-type 并序列化', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.postJson(server.uri('/j'), {'a': 1, 'b': 'x'});
      expect(server.last.header('content-type'), contains('application/json'));
      expect(jsonDecode(server.last.bodyText), {'a': 1, 'b': 'x'});
    });

    test('post 传 Map 自动按表单发送', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.post(server.uri('/f'), body: {'a': '1 2'});
      expect(server.last.bodyText, 'a=1+2');
      expect(
        server.last.header('content-type'),
        contains('x-www-form-urlencoded'),
      );
    });

    test('post 传原始字节不改动', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = newClient();
      await net.post(
        server.uri('/raw'),
        body: utf8.encode('raw-body'),
        headers: {'Content-Type': 'text/plain'},
      );
      expect(server.last.bodyText, 'raw-body');
      expect(server.last.header('content-type'), 'text/plain');
    });
  });

  group('超时与重试', () {
    test('超时抛 TimeoutException', () async {
      server = await TestServer.start((req, raw) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await sendHtml(raw, 'late');
      });
      net = newClient(timeout: const Duration(milliseconds: 150));
      await expectLater(
        net.get(server.uri('/slow')),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('连接中断后重试成功', () async {
      server = await TestServer.start((req, raw) async {
        if (server.requestCount <= 2) {
          final socket = await raw.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        await sendHtml(raw, 'recovered');
      });
      net = newClient(maxRetries: 2);
      final resp = await net.get(server.uri('/flaky'));
      expect(resp.text(), 'recovered');
      expect(server.requestCount, 3);
    });

    test('maxRetries=0 时连接错误直接抛', () async {
      server = await TestServer.start((req, raw) async {
        final socket = await raw.response.detachSocket(writeHeaders: false);
        socket.destroy();
      });
      net = newClient(maxRetries: 0);
      await expectLater(net.get(server.uri('/dead')), throwsA(anything));
    });
  });

  group('编码与压缩', () {
    test('响应头 charset=gbk 时 text 正确', () async {
      final gbkBody = List<int>.from(
        // "中文" 的 GBK 字节
        const [0xD6, 0xD0, 0xCE, 0xC4],
      );
      server = await TestServer.start(
        (req, raw) => sendBytes(
          raw,
          gbkBody,
          headers: {'content-type': 'text/html; charset=gbk'},
        ),
      );
      net = newClient();
      final resp = await net.get(server.uri('/gbk'));
      expect(resp.text(), '中文');
    });

    test('显式 charset 参数压过响应头', () async {
      server = await TestServer.start(
        (req, raw) => sendBytes(
          raw,
          utf8.encode('中文'),
          headers: {'content-type': 'text/html; charset=gbk'},
        ),
      );
      net = newClient();
      final resp = await net.get(server.uri('/u'), charset: 'utf-8');
      expect(resp.text(), '中文');
    });

    test('gzip 响应能解压', () async {
      final payload = utf8.encode('gzipped-中文');
      server = await TestServer.start(
        (req, raw) => sendBytes(
          raw,
          gzip.encode(payload),
          headers: {
            'content-type': 'text/html; charset=utf-8',
            'content-encoding': 'gzip',
          },
        ),
      );
      net = newClient();
      final resp = await net.get(
        server.uri('/gz'),
        headers: {'Accept-Encoding': 'gzip'},
      );
      expect(resp.text(), 'gzipped-中文');
    });

    test('json() 解析响应体', () async {
      server = await TestServer.start(
        (req, raw) => sendHtml(
          raw,
          '{"ok":true,"n":3}',
          contentType: 'application/json; charset=utf-8',
        ),
      );
      net = newClient();
      final resp = await net.get(server.uri('/j'));
      final data = resp.json();
      expect(data, isA<Map<String, dynamic>>());
      expect((data as Map)['ok'], true);
      expect(data['n'], 3);
    });
  });

  group('日志脱敏与工具', () {
    test('sanitizeUri 抹掉敏感参数值', () {
      final uri = Uri.parse(
        'https://a.com/api?token=secret&key=k&q=1&sign=s&password=p',
      );
      final safe = sanitizeUri(uri).toString();
      expect(safe, isNot(contains('secret')));
      expect(safe, isNot(contains('sign=s')));
      expect(safe, contains('q=1'));
      expect(safe, contains('token=***'));
    });

    test('sanitizeUri 无敏感参数时原样返回', () {
      final uri = Uri.parse('https://a.com/a?page=2');
      expect(sanitizeUri(uri).toString(), uri.toString());
    });

    test('splitSetCookieHeader 不把 Expires 的逗号当分隔', () {
      final parts = splitSetCookieHeader(
        'a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT, b=2; Path=/',
      );
      expect(parts.length, 2);
      expect(parts[0], 'a=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT');
      expect(parts[1], 'b=2; Path=/');
    });

    test('mergeCookieHeaders 同名以前者为准', () {
      expect(mergeCookieHeaders('a=1; b=2', 'b=3; c=4'), 'a=1; b=2; c=4');
    });

    test('日志开关不改变行为', () async {
      server = await TestServer.start((req, raw) => sendHtml(raw, 'ok'));
      net = NetClient(
        logging: true,
        limiter: testLimiter(),
        maxRetries: 0,
      );
      final resp = await net.get(server.uri('/a'));
      expect(resp.statusCode, 200);
    });
  });
}
