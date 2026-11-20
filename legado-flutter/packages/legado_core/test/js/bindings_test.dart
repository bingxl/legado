import 'package:test/test.dart';

import 'package:legado_core/src/js/java_host.dart';
import 'package:legado_core/src/js/values.dart';

import 'helpers.dart';

void main() {
  group('普通值 bindings', () {
    test('字符串/数字/Map/List 直接可见', () async {
      expect(
        await run('baseUrl + "|" + result + "|" + meta.a + "|" + list[1]', bindings: {
          'baseUrl': 'https://x',
          'result': 3,
          'meta': {'a': 'A'},
          'list': [1, 2],
        }),
        'https://x|3|A|2',
      );
    });

    test('脚本可以读写 bindings 里的 Map', () async {
      final meta = <String, Object?>{'a': 1};
      final v = await run('meta.a = 9; meta.a', bindings: {'meta': meta});
      // 脚本内部读写绑定值两边都一样
      expect(v, 9);
      // 但「改动传回 Dart 侧」只有解释器能做到：QuickJS 在独立 isolate 里，
      // 绑定值是拷贝过去的（真实 Rhino 里也是拷贝，书源不该依赖这个）。
      if (dartEngine) expect(meta['a'], 9);
    });
  });

  group('Dart 函数桥接', () {
    test('Object? Function(List<Object?>)', () async {
      final v = await run('twice(3)', bindings: {
        'twice': (List<Object?> args) => (args[0] as num) * 2,
      });
      expect(v, 6);
    });

    test('嵌套在 Map 里的函数', () async {
      final v = await run('host.greet("x")', bindings: {
        'host': {
          'name': 'h',
          'greet': (List<Object?> args) => 'hi ${args[0]}',
        },
      });
      expect(v, 'hi x');
    });

    test('函数返回值参与 JS 运算', () async {
      final v = await run('var n = toNum("18"); n + 2', bindings: {
        'toNum': (List<Object?> args) => int.parse(args[0] as String),
      });
      expect(v, 20);
    });
  });

  group('JsHostObject', () {
    test('方法调用与属性读取', () async {
      final host = JsHostObject(
        label: 'host',
        props: {'version': 2},
        methods: {'add': (args) => (args[0] as num) + (args[1] as num)},
      );
      expect(await run('[host.version, host.add(1, 2)]', bindings: {'host': host}), [2, 3]);
    });

    test('缺少方法时是 undefined', () async {
      final host = JsHostObject(label: 'host');
      expect(await run('typeof host.nope', bindings: {'host': host}), 'undefined');
    });
  });

  group('java 对象', () {
    test('ajax 通过回调注入', () async {
      final seen = <String>[];
      final java = createJavaObject(ajax: (url) {
        seen.add(url);
        return 'BODY:$url';
      });
      final v = await run('java.ajax("https://a")', bindings: {'java': java});
      expect(v, 'BODY:https://a');
      expect(seen, ['https://a']);
    });

    test('ajax 未注入时报清晰错误', () async {
      final java = createJavaObject();
      final e = await expectError('java.ajax("u")', bindings: {'java': java});
      expect(e.toString(), contains('未接入网络层'));
    });

    test('md5Encode / md5Encode16', () async {
      final java = createJavaObject();
      expect(
        await run('java.md5Encode("abc")', bindings: {'java': java}),
        '900150983cd24fb0d6963f7d28e17f72',
      );
      expect(
        await run('java.md5Encode16("abc")', bindings: {'java': java}),
        '3cd24fb0d6963f7d',
      );
    });

    test('base64 往返', () async {
      final java = createJavaObject();
      expect(await run('java.base64Decode(java.base64Encode("中文abc"))', bindings: {'java': java}), '中文abc');
    });

    test('hex 往返', () async {
      final java = createJavaObject();
      expect(
        await run('java.hexDecodeToString(java.hexEncodeToString("hello"))', bindings: {'java': java}),
        'hello',
      );
    });

    test('strToBytes / bytesToStr', () async {
      final java = createJavaObject();
      expect(await run('java.bytesToStr(java.strToBytes("abc"))', bindings: {'java': java}), 'abc');
    });

    test('put / get 变量表', () async {
      final java = createJavaObject();
      expect(await run('java.put("k", 1); java.get("k")', bindings: {'java': java}), 1);
    });

    test('timeFormat 输出 yyyy/MM/dd HH:mm', () async {
      final java = createJavaObject();
      final s = await run('java.timeFormat(0)', bindings: {'java': java}) as String;
      expect(RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$').hasMatch(s), true);
    });

    test('getString 由规则层注入', () async {
      final java = createJavaObject(getString: (rule) => 'rule:$rule');
      expect(await run('java.getString("//div")', bindings: {'java': java}), 'rule://div');
    });

    test('getString 未注入时提示需要规则层', () async {
      final java = createJavaObject();
      final e = await expectError('java.getString("x")', bindings: {'java': java});
      expect(e.toString(), contains('规则层'));
    });

    test('encodeURI 空格转加号', () async {
      final java = createJavaObject();
      expect(await run('java.encodeURI("a b")', bindings: {'java': java}), 'a+b');
    });

    test('htmlFormat 去标签', () async {
      final java = createJavaObject();
      expect(await run('java.htmlFormat("<p>a<br/>b</p>")', bindings: {'java': java}), 'a\nb');
    });

    test('toast 回调', () async {
      final msgs = <String>[];
      final java = createJavaObject(toast: (m) => msgs.add(m ?? ''));
      await run('java.toast("hi")', bindings: {'java': java});
      expect(msgs, ['hi']);
    });
  });
}
