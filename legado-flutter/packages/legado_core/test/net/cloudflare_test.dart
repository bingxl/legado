import 'dart:async';

import 'package:legado_core/src/net/net.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('判定规则', () {
    test('只认 cf-mitigated: challenge', () {
      expect(
        isCloudflareChallenge(403, {
          'cf-mitigated': ['challenge'],
        }),
        isTrue,
      );
      expect(
        isCloudflareChallenge(503, {
          'cf-mitigated': ['CHALLENGE'],
        }),
        isTrue,
        reason: '值的大小写不该影响判定',
      );
    });

    test('2xx 一律不判', () {
      expect(
        isCloudflareChallenge(200, {
          'cf-mitigated': ['challenge'],
        }),
        isFalse,
      );
    });

    test('Server: cloudflare 不作数', () {
      expect(
        isCloudflareChallenge(403, {
          'server': ['cloudflare'],
        }),
        isFalse,
      );
    });

    test('正文里的挑战页字样不作数', () {
      // 判定只看头，正文不参与——这条是为了防止「页脚写了 Just a moment」误伤。
      expect(
        isCloudflareChallenge(403, {
          'server': ['cloudflare'],
          'content-type': ['text/html'],
        }),
        isFalse,
      );
    });

    test('判定依据文案带状态码', () {
      final reason = cloudflareChallengeReason(403, {
        'cf-mitigated': ['challenge'],
      });
      expect(reason, contains('403'));
      expect(cloudflareChallengeReason(200, {}), isNull);
    });
  });

  group('端到端处置', () {
    late TestServer server;

    tearDown(() async {
      await server.close();
    });

    Future<TestServer> startProtected() {
      return TestServer.start((req, raw) async {
        final cookie = req.header('cookie') ?? '';
        if (cookie.contains('cf_clearance=good')) {
          await sendHtml(raw, 'unlocked');
          return;
        }
        raw.response.statusCode = 403;
        raw.response.headers
          ..set('cf-mitigated', 'challenge')
          ..set('content-type', 'text/html; charset=utf-8');
        raw.response.add(utf8Bytes('<html>challenge</html>'));
        await raw.response.close();
      });
    }

    test('回调拿到 cookie 后重试成功', () async {
      server = await startProtected();
      var calls = 0;
      final net = NetClient(
        limiter: testLimiter(),
        maxRetries: 0,
        onChallenge: (req) async {
          calls++;
          expect(req.statusCode, 403);
          return const ChallengeSolution(
            cookie: 'cf_clearance=good',
            userAgent: 'UA-AFTER-CHALLENGE',
          );
        },
      );
      final resp = await net.get(server.uri('/protected'));
      expect(resp.statusCode, 200);
      expect(resp.text(), 'unlocked');
      expect(calls, 1);
      expect(server.requestCount, 2);
      // 重试必须换成验证时的 UA：cf_clearance 与 UA 绑定。
      expect(server.last.header('user-agent'), 'UA-AFTER-CHALLENGE');
      expect(net.cookies.getCookieHeader(server.base), contains('cf_clearance=good'));
      net.close();
    });

    test('验证结果合并而不是覆盖登录态', () async {
      server = await TestServer.start((req, raw) async {
        final cookie = req.header('cookie') ?? '';
        if (req.uri.path == '/pre') {
          raw.response.headers.add('set-cookie', 'login=tom; Path=/');
          await sendHtml(raw, 'ok');
          return;
        }
        if (cookie.contains('cf_clearance=good') && cookie.contains('login=tom')) {
          await sendHtml(raw, 'both');
          return;
        }
        raw.response.statusCode = 403;
        raw.response.headers.set('cf-mitigated', 'challenge');
        await raw.response.close();
      });
      final net = NetClient(
        limiter: testLimiter(),
        maxRetries: 0,
        onChallenge: (req) async =>
            const ChallengeSolution(cookie: 'cf_clearance=good'),
      );
      await net.get(server.uri('/pre'));
      final resp = await net.get(server.uri('/protected'));
      expect(resp.text(), 'both');
      net.close();
    });

    test('没有 handler 时抛 CloudflareChallengeException', () async {
      server = await startProtected();
      final net = NetClient(limiter: testLimiter(), maxRetries: 0);
      await expectLater(
        net.get(server.uri('/protected')),
        throwsA(
          isA<CloudflareChallengeException>().having(
            (e) => e.uri.path,
            'uri',
            '/protected',
          ),
        ),
      );
      net.close();
    });

    test('用户放弃时原样返回 403', () async {
      server = await startProtected();
      final net = NetClient(
        limiter: testLimiter(),
        maxRetries: 0,
        onChallenge: (req) async => const ChallengeSolution(skip: true),
      );
      final resp = await net.get(server.uri('/protected'));
      expect(resp.statusCode, 403);
      expect(server.requestCount, 1);
      net.close();
    });

    test('只重试一次，不会无限弹窗', () async {
      server = await TestServer.start((req, raw) async {
        raw.response.statusCode = 403;
        raw.response.headers.set('cf-mitigated', 'challenge');
        await raw.response.close();
      });
      var calls = 0;
      final net = NetClient(
        limiter: testLimiter(),
        maxRetries: 0,
        onChallenge: (req) async {
          calls++;
          return const ChallengeSolution(cookie: 'cf_clearance=good');
        },
      );
      final resp = await net.get(server.uri('/always'));
      expect(resp.statusCode, 403);
      expect(calls, 1);
      expect(server.requestCount, 2);
      net.close();
    });

    test('只拿到页面正文时当作 200 返回', () async {
      server = await startProtected();
      final net = NetClient(
        limiter: testLimiter(),
        maxRetries: 0,
        onChallenge: (req) async =>
            const ChallengeSolution(body: '<html>rendered</html>'),
      );
      final resp = await net.get(server.uri('/protected'));
      expect(resp.statusCode, 200);
      expect(resp.text(), '<html>rendered</html>');
      net.close();
    });

    test('ChallengeState 记录 UA 覆盖并可清除', () {
      final state = ChallengeState();
      state.setUserAgent('a.com', 'UA1');
      expect(state.userAgentFor('A.COM'), 'UA1');
      state.setUserAgent('a.com', null);
      expect(state.userAgentFor('a.com'), isNull);
    });

    test('同一 host 的验证串行执行', () async {
      final state = ChallengeState();
      final order = <String>[];
      Future<void> job(String tag, int delayMs) {
        return state.serialize('a.com', () async {
          order.add('$tag-start');
          await Future<void>.delayed(Duration(milliseconds: delayMs));
          order.add('$tag-end');
        });
      }

      await Future.wait([job('x', 60), job('y', 10)]);
      expect(order, ['x-start', 'x-end', 'y-start', 'y-end']);
    });
  });
}
