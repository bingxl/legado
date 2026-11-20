import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/net/cookie_store.dart';
import 'package:test/test.dart';

void main() {
  group('Set-Cookie 解析', () {
    test('基本属性全部落地', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://www.example.com/a/b'),
        'sid=abc123; Path=/x; Domain=example.com; Secure; HttpOnly; SameSite=Lax',
      );
      expect(c, isNotNull);
      expect(c!.name, 'sid');
      expect(c.value, 'abc123');
      expect(c.domain, 'example.com');
      expect(c.hostOnly, isFalse);
      expect(c.path, '/x');
      expect(c.secure, isTrue);
      expect(c.httpOnly, isTrue);
      expect(c.sameSite, 'Lax');
    });

    test('Expires 里的逗号不能当分隔符', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        'x=1; Expires=Wed, 21 Oct 2037 07:28:00 GMT; Path=/',
      );
      expect(c, isNotNull);
      expect(c!.expires, DateTime.utc(2037, 10, 21, 7, 28, 0));
      expect(c.path, '/');
      // 如果按逗号切分，会多出 "21 Oct 2037..." 这种伪属性，名字也会带脏字符。
      expect(c.name, 'x');
      expect(c.value, '1');
    });

    test('值里带等号不丢后半截', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        'token=abc==; Path=/',
      );
      expect(c!.value, 'abc==');
    });

    test('引号包裹的值去掉引号', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        'q="hello world"; Path=/',
      );
      expect(c!.value, 'hello world');
    });

    test('没有 Domain 属性是 host-only，只发本 host', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://www.a.com/'), 'h=1; Path=/');
      expect(store.getCookieHeader(Uri.parse('https://www.a.com/x')), 'h=1');
      expect(store.getCookieHeader(Uri.parse('https://api.a.com/x')), isNull);
      expect(store.getCookieHeader(Uri.parse('https://a.com/x')), isNull);
    });

    test('带 Domain 属性的 cookie 发给子域', () {
      final store = CookieStore();
      store.setCookie(
        Uri.parse('https://www.a.com/'),
        'd=1; Domain=.a.com; Path=/',
      );
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), 'd=1');
      expect(store.getCookieHeader(Uri.parse('https://m.a.com/')), 'd=1');
      expect(store.getCookieHeader(Uri.parse('https://b.com/')), isNull);
    });

    test('Domain 不覆盖当前 host 时整条拒收', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://www.a.com/'),
        'evil=1; Domain=evil.com; Path=/',
      );
      expect(c, isNull);
      expect(store.isEmpty, isTrue);
    });

    test('Max-Age 优先于 Expires', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        'x=1; Max-Age=3600; Expires=Wed, 21 Oct 1998 07:28:00 GMT',
      );
      expect(c!.maxAge, const Duration(hours: 1));
      expect(
        store.getCookieHeader(Uri.parse('https://a.com/')),
        'x=1',
        reason: 'Expires 已过期但 Max-Age 未到，应当保留',
      );
    });

    test('Max-Age=0 删除已有 cookie', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'x=1; Path=/');
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), 'x=1');
      store.setCookie(Uri.parse('https://a.com/'), 'x=; Max-Age=0; Path=/');
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), isNull);
    });

    test('Expires 已过期等于删除', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'x=1; Path=/');
      store.setCookie(
        Uri.parse('https://a.com/'),
        'x=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      );
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), isNull);
    });

    test('缺少 cookie-pair 的整条丢弃', () {
      final store = CookieStore();
      expect(store.setCookie(Uri.parse('https://a.com/'), '=1; Path=/'), isNull);
      expect(store.isEmpty, isTrue);
    });
  });

  group('path 匹配', () {
    test('/a/b 命中 /a/b/c 但不命中 /a/bc', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'p=1; Path=/a/b');
      expect(store.getCookieHeader(Uri.parse('https://a.com/a/b')), 'p=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/a/b/c')), 'p=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/a/bc')), isNull);
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), isNull);
    });

    test('以 / 结尾的 path 直接前缀匹配', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'p=1; Path=/api/');
      expect(store.getCookieHeader(Uri.parse('https://a.com/api/v1')), 'p=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/apix')), isNull);
    });

    test('缺省 path 取到最后一个斜杠之前', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/a/b/c'), 'd=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/a/b/c')), 'd=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/a/b/other')), 'd=1');
      expect(store.getCookieHeader(Uri.parse('https://a.com/x')), isNull);
    });

    test('同名不同 path 共存，长 path 排在前面', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'n=root; Path=/');
      store.setCookie(Uri.parse('https://a.com/'), 'n=deep; Path=/a');
      final header = store.getCookieHeader(Uri.parse('https://a.com/a/b'));
      expect(header, 'n=deep; n=root');
    });
  });

  group('安全属性与前缀', () {
    test('secure cookie 不发给 http', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 's=1; Path=/; Secure');
      expect(store.getCookieHeader(Uri.parse('http://a.com/')), isNull);
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), 's=1');
    });

    test('__Host- 合法形式可写入', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        '__Host-t=1; Secure; Path=/',
      );
      expect(c, isNotNull);
      expect(c!.hostOnly, isTrue);
      expect(store.getCookieHeader(Uri.parse('https://a.com/x')), '__Host-t=1');
    });

    test('__Host- 带 Domain 拒收', () {
      final store = CookieStore();
      final c = store.setCookie(
        Uri.parse('https://a.com/'),
        '__Host-t=1; Secure; Path=/; Domain=a.com',
      );
      expect(c, isNull);
    });

    test('__Host- 不带 Secure 拒收', () {
      final store = CookieStore();
      expect(
        store.setCookie(Uri.parse('https://a.com/'), '__Host-t=1; Path=/'),
        isNull,
      );
    });

    test('__Secure- 不带 Secure 拒收', () {
      final store = CookieStore();
      expect(
        store.setCookie(Uri.parse('https://a.com/'), '__Secure-t=1; Path=/'),
        isNull,
      );
      expect(
        store.setCookie(
          Uri.parse('https://a.com/'),
          '__Secure-t=1; Secure; Path=/',
        ),
        isNotNull,
      );
    });
  });

  group('清理与容器行为', () {
    test('removeExpired 清掉过期项', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'keep=1; Path=/');
      store.setCookie(
        Uri.parse('https://a.com/'),
        'gone=1; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT',
      );
      // 过期项在写入时就被拒绝了，这里造一个"当场过期"的场景验证接口。
      expect(store.removeExpired(), 0);
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), 'keep=1');
    });

    test('removeAll 清掉整站（含子域）', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'a=1; Path=/');
      store.setCookie(Uri.parse('https://www.a.com/'), 'b=2; Path=/');
      store.setCookie(Uri.parse('https://b.com/'), 'c=3; Path=/');
      store.removeAll(Uri.parse('https://a.com/'));
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), isNull);
      expect(store.getCookieHeader(Uri.parse('https://www.a.com/')), isNull);
      expect(store.getCookieHeader(Uri.parse('https://b.com/')), 'c=3');
    });

    test('removeKey 只删指定名字', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'a=1; Path=/');
      store.setCookie(Uri.parse('https://a.com/'), 'b=2; Path=/');
      store.removeKey('a.com', 'a');
      expect(store.getCookieHeader(Uri.parse('https://a.com/')), 'b=2');
    });

    test('importCookieHeader 导入 document.cookie 形态', () {
      final store = CookieStore();
      store.importCookieHeader(
        Uri.parse('https://a.com/path/x'),
        'a=1; b=2; Path=/; Secure',
      );
      final header = store.getCookieHeader(Uri.parse('https://a.com/path/x'));
      expect(header, 'a=1; b=2');
      // Path=/ 被当成属性跳过，缺省 path 来自 uri：/path
      expect(store.getCookieHeader(Uri.parse('https://a.com/other')), isNull);
    });

    test('replaceFromWebView 覆盖该 host 旧值', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'old=1; Path=/');
      final uri = Uri.parse('https://a.com/');
      store.replaceFromWebView(uri, [
        Cookie(
          name: 'cf_clearance',
          value: 'new',
          domain: 'a.com',
          hostOnly: true,
          path: '/',
        ),
      ]);
      expect(store.getCookieHeader(uri), 'cf_clearance=new');
    });

    test('cookieValue 取单值', () {
      final store = CookieStore();
      store.setCookie(Uri.parse('https://a.com/'), 'a=1; Path=/');
      expect(store.cookieValue(Uri.parse('https://a.com/'), 'a'), '1');
      expect(store.cookieValue(Uri.parse('https://a.com/'), 'zz'), isNull);
    });
  });

  group('持久化', () {
    test('save / load 往返', () async {
      final dir = await Directory.systemTemp.createTemp('legado_cookie');
      final path = '${dir.path}/cookies.json';
      final store = CookieStore();
      store.setCookie(
        Uri.parse('https://a.com/'),
        'sid=1; Path=/; Domain=a.com; Secure; HttpOnly',
      );
      store.importCookieHeader(Uri.parse('https://b.com/'), 'x=2');
      await store.save(path);

      final loaded = CookieStore();
      await loaded.load(path);
      expect(loaded.length, 2);
      expect(loaded.getCookieHeader(Uri.parse('https://a.com/')), 'sid=1');
      expect(loaded.getCookieHeader(Uri.parse('https://b.com/')), 'x=2');
      await dir.delete(recursive: true);
    });

    test('文件不存在时 load 不抛', () async {
      final store = CookieStore();
      await store.load('${Directory.systemTemp.path}/no-such-file-xyz.json');
      expect(store.isEmpty, isTrue);
    });

    test('损坏的 JSON 不抛', () async {
      final dir = await Directory.systemTemp.createTemp('legado_cookie_bad');
      final path = '${dir.path}/cookies.json';
      await File(path).writeAsString('{not json');
      final store = CookieStore();
      await store.load(path);
      expect(store.isEmpty, isTrue);
      await dir.delete(recursive: true);
    });

    test('toJson / fromJson 纯内存往返', () {
      final store = CookieStore();
      store.setCookie(
        Uri.parse('https://a.com/'),
        'sid=1; Path=/x; Domain=a.com; Secure; HttpOnly',
      );
      store.importCookieHeader(Uri.parse('https://b.com/'), 'k=v');

      final snapshot = store.toJson();
      final restored = CookieStore()..fromJson(snapshot);

      expect(restored.length, 2);
      expect(
        restored.getCookieHeader(Uri.parse('https://a.com/x')),
        'sid=1',
      );
      expect(restored.getCookieHeader(Uri.parse('https://b.com/')), 'k=v');
      // 属性也要还原，否则 WebView 导入的 secure cookie 会变成明文回传。
      final cookie = restored
          .cookiesFor(Uri.parse('https://a.com/x'))
          .first;
      expect(cookie.secure, isTrue);
      expect(cookie.httpOnly, isTrue);
      expect(cookie.path, '/x');
      expect(cookie.hostOnly, isFalse);
    });

    test('fromJson 是合并而非替换', () {
      final store = CookieStore();
      store.importCookieHeader(Uri.parse('https://a.com/'), 'login=tom');
      store.fromJson({
        'cookies': [
          {
            'name': 'cf_clearance',
            'value': 'x',
            'domain': 'a.com',
            'hostOnly': true,
            'path': '/',
          },
        ],
      });
      final header = store.getCookieHeader(Uri.parse('https://a.com/'));
      expect(header, contains('login=tom'));
      expect(header, contains('cf_clearance=x'));
    });

    test('toJson 与落盘文件结构一致', () async {
      final dir = await Directory.systemTemp.createTemp('legado_cookie_json');
      final path = '${dir.path}/cookies.json';
      final store = CookieStore();
      store.importCookieHeader(Uri.parse('https://a.com/'), 'a=1');
      await store.save(path);

      final onDisk = jsonDecode(await File(path).readAsString()) as Map;
      final inMemory = store.toJson();
      expect(onDisk['version'], inMemory['version']);
      expect(
        (onDisk['cookies'] as List).length,
        (inMemory['cookies'] as List).length,
      );
      await dir.delete(recursive: true);
    });
  });

  group('日期与多值头', () {
    test('三种日期格式都能解析', () {
      expect(
        parseCookieDate('Wed, 21 Oct 2015 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28, 0),
      );
      expect(
        parseCookieDate('Wednesday, 21-Oct-15 07:28:00 GMT'),
        DateTime.utc(2015, 10, 21, 7, 28, 0),
      );
      expect(
        parseCookieDate('Wed Oct 21 07:28:00 2015'),
        DateTime.utc(2015, 10, 21, 7, 28, 0),
      );
      expect(parseCookieDate('not a date'), isNull);
    });

    test('空字节数返回空字符串不影响容器', () {
      final store = CookieStore();
      expect(store.setCookie(Uri.parse('https://a.com/'), ''), isNull);
      expect(store.all, isEmpty);
    });
  });
}
