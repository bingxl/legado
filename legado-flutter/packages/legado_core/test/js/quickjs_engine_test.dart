import 'dart:async';

import 'package:legado_core/src/js/java_host.dart';
import 'package:legado_core/src/js/js_exception.dart';
import 'package:legado_core/src/js/quickjs_engine.dart';
import 'package:legado_core/src/js/values.dart';
import 'package:test/test.dart';

/// QuickJS 引擎的契约测试。
///
/// 除了「能算数」，重点覆盖宿主桥接的几个易错点：
/// 回调可以返回 Future、可以返回宿主对象再继续调方法、
/// 嵌套 eval（`java.getString` 会走这条路）不能死锁。
void main() {
  late QuickJsEngine engine;

  setUp(() => engine = QuickJsEngine());
  tearDown(() => engine.dispose());

  group('基础语义', () {
    test('最后一条表达式语句的值', () async {
      expect(await engine.eval('var a = 1; a + 1'), 2);
    });

    test('没有表达式时返回 null', () async {
      expect(await engine.eval('var a = 1;'), isNull);
    });

    test('Map / List 原样返回', () async {
      expect(await engine.eval('({a: [1, 2], b: "x"})'), {
        'a': [1, 2],
        'b': 'x',
      });
    });

    test('现代语法：箭头函数 / 模板串 / 解构 / 可选链 / 展开', () async {
      final v = await engine.eval(r'''
        var o = {a: {b: 7}};
        var [x, y] = [1, 2];
        var s = `${x + y}:${o?.a?.b}:${o?.missing?.deep ?? 'd'}`;
        var arr = [...[1, 2], 3].map((n) => n * 2);
        s + '|' + arr.join(',');
      ''');
      expect(v, '3:7:d|2,4,6');
    });

    test('顶层 return 兼容（Dart 引擎允许这种写法）', () async {
      expect(await engine.eval('var a = 1;\nreturn a + 4;'), 5);
    });

    test('多次执行互不污染', () async {
      await engine.eval('var x = 1;');
      expect(await engine.eval('typeof x'), 'undefined');
    });

    test('反复执行相同脚本不会因 const 重声明报错', () async {
      for (var i = 0; i < 3; i++) {
        expect(await engine.eval('const n = $i; n'), i);
      }
    });

    test('递归 100 层不溢出（QuickJS 真实调用栈）', () async {
      // JS 栈上限按 worker 线程剩余栈量设（见 quickjs_bridge.c），
      // 桌面实测可到 ~160 层；这里取一个留有余量的值。
      final v = await engine.eval('''
        function sum(n) { return n <= 0 ? 0 : n + sum(n - 1); }
        sum(100);
      ''');
      expect(v, 5050);
    });
  });

  group('宿主桥接', () {
    test('bindings 里的 Dart 函数可调用', () async {
      final v = await engine.eval('hostAdd(2, 3)', bindings: {
        'hostAdd': (List<Object?> args) => (args[0]! as num) + (args[1]! as num),
      });
      expect(v, 5);
    });

    test('java.ajax 返回 Future：脚本拿到的是最终结果', () async {
      final java = createJavaObject(
        ajax: (url) async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return 'body:$url';
        },
      );
      final v = await engine.eval(
        'var r = java.ajax("/a"); r;',
        bindings: {'java': java},
      );
      expect(v, 'body:/a');
    });

    test('异步回调参与 filter / sort 也能拿到最终值', () async {
      final java = createJavaObject(
        extraMethods: {
          'twice': (args) async => (args.first! as num) * 2,
        },
      );
      expect(
        await engine.eval(
          '[1,2,3,4].filter(function (x) { return java.twice(x) > 4; }).join(",");',
          bindings: {'java': java},
        ),
        '3,4',
      );
      expect(
        await engine.eval(
          '[3,1,2].sort(function (a, b) { return java.twice(a) - java.twice(b); }).join(",");',
          bindings: {'java': java},
        ),
        '1,2,3',
      );
    });

    test('宿主函数返回宿主对象，脚本可以继续调它的方法', () async {
      final java = createJavaObject(
        connect: (url, body, headers) {
          return JsHostObject(
            methods: {
              'body': (args) => '{"statusCode":200,"url":"$url"}',
            },
          );
        },
      );
      final v = await engine.eval(
        'var j = JSON.parse(java.connect("https://x/api").body()); j.url;',
        bindings: {'java': java},
      );
      expect(v, 'https://x/api');
    });

    test('宿主对象属性可读', () async {
      final java = createJavaObject(androidId: 'aid-1', props: {'version': 7});
      expect(
        await engine.eval('java.androidId + ":" + java.version', bindings: {'java': java}),
        'aid-1:7',
      );
    });

    test('java.put / java.get 变量在同一段脚本内可见', () async {
      final java = createJavaObject();
      final v = await engine.eval(
        'java.put("k", "v1"); java.get("k");',
        bindings: {'java': java},
      );
      expect(v, 'v1');
    });

    test('嵌套宿主回调里再次 eval（java.getString 那条路）不会死锁', () async {
      late Future<Object?> inner;
      final java = createJavaObject(
        getString: (rule) {
          // 规则层解析子规则：会拿同一个引擎再跑一段脚本
          inner = engine.eval('[1,2,3].length');
          return inner.then((v) => 'len=$v');
        },
      );
      final v = await engine
          .eval(
            'var s = java.getString("x"); s;',
            bindings: {'java': java},
          )
          .timeout(const Duration(seconds: 10));
      expect(v, 'len=3');
      expect(await inner, 3);
    });

    test('宿主回调可以并发执行（多段脚本同时求值）', () async {
      final java = createJavaObject(
        ajax: (url) async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 'R:$url';
        },
      );
      final values = await Future.wait([
        for (var i = 0; i < 6; i++)
          engine.eval('java.ajax("/$i")', bindings: {'java': java}),
      ]);
      expect(values, [for (var i = 0; i < 6; i++) 'R:/$i']);
    });
  });

  group('报错', () {
    test('运行时错误带行号与源码行', () async {
      final e = await _expectError(engine, 'var a = 1;\nvar b = a.c.d;\n');
      expect(e.line, 2);
      expect(e.toString(), contains('第 2 行'));
      expect(e.toString(), contains('var b = a.c.d;'));
    });

    test('语法错误标记 isSyntax', () async {
      final e = await _expectError(engine, 'var a = 1;\nvar b = ;\n');
      expect(e.line, 2);
      expect(e.isSyntax, true);
    });

    test('未定义变量 / 调用非函数有中文提示', () async {
      expect(
        (await _expectError(engine, 'notDefined + 1')).message,
        contains('未定义'),
      );
      expect(
        (await _expectError(engine, 'var a = 1; a();')).message,
        contains('不是函数'),
      );
    });

    test('宿主函数抛异常时脚本可以 try/catch 抓住', () async {
      final java = createJavaObject(
        ajax: (url) async => throw StateError('network down'),
      );
      final v = await engine.eval(
        'try { java.ajax("/c"); } catch (e) { "caught:" + e.message; }',
        bindings: {'java': java},
      );
      expect(v, startsWith('caught:'));
      expect(v, contains('network down'));
    });
  });

  group('其他', () {
    test('console.log 走 onLog 通道', () async {
      final logs = <String>[];
      final logEngine = QuickJsEngine(
        onLog: (level, msg) => logs.add('$level:$msg'),
      );
      addTearDown(logEngine.dispose);
      await logEngine.eval('console.log("hello", 42);');
      // 与 Dart 解释器一致：console.* 一律 info 级别。
      expect(logs, ['info:hello 42']);
    });

    test('脚本超时不影响后续调用（worker 隔离）', () async {
      // 不是真超时测试，只确认一次普通失败之后池子还能用
      await _expectError(engine, 'throw new Error("boom")');
      expect(await engine.eval('1 + 1'), 2);
    });
  });
}

Future<JsException> _expectError(QuickJsEngine engine, String script) async {
  try {
    final v = await engine.eval(script);
    throw StateError('期望抛出 JsException，但返回了 $v');
  } on JsException catch (e) {
    return e;
  }
}
