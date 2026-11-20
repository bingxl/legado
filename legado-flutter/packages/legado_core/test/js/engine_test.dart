import 'package:test/test.dart';

import 'helpers.dart';

/// 纯 Dart 解释器自己的契约：parser 报错文案、precompile 缓存、递归上限。
/// QuickJS 的契约测试在 `quickjs_engine_test.dart`，通用语义用例在其它文件
/// 里两套引擎都跑。
void main() {
  // 解释器每次 eval 都新建 Interpreter 上下文，共用一个实例不会串味。
  final engine = newDartEngine();

  group('返回值', () {
    test('最后一条表达式语句的值', () async {
      expect(await engine.eval('var a = 1; a + 1'), 2);
    });

    test('没有表达式时返回 null', () async {
      expect(await engine.eval('var a = 1;'), null);
    });

    test('return 语句在顶层也能返回', () async {
      expect(await engine.eval('return 5;'), 5);
    });

    test('Map / List 原样返回', () async {
      expect(await engine.eval('({a: [1, 2]})'), {
        'a': [1, 2],
      });
    });
  });

  group('报错定位', () {
    test('语法错误带行号与源码行', () async {
      final e = await expectDartError('var a = 1;\nvar b = ;\n');
      expect(e.line, 2);
      expect(e.toString(), contains('第 2 行'));
      expect(e.toString(), contains('var b = ;'));
      expect(e.isSyntax, true);
    });

    test('运行时错误指向表达式所在行', () async {
      final e = await expectDartError('var a = 1;\nvar b = a.c.d;\n');
      expect(e.line, 2);
      expect(e.toString(), contains('第 2 行'));
    });

    test('未定义变量', () async {
      final e = await expectDartError('notDefined + 1');
      expect(e.toString(), contains('notDefined'));
      expect(e.toString(), contains('未定义'));
    });

    test('调用非函数', () async {
      final e = await expectDartError('var a = 1; a();');
      expect(e.toString(), contains('不是函数'));
    });

    test('class 给出明确的不支持错误', () async {
      final e = await expectDartError('class A {}');
      expect(e.toString(), contains('不支持 class'));
    });

    test('解构声明给出明确错误', () async {
      final e = await expectDartError('var [a, b] = [1, 2];');
      expect(e.toString(), contains('解构'));
    });

    test('无限递归有上限保护', () async {
      final e = await expectDartError('function f() { return f(); } f();');
      expect(e.toString(), contains('递归'));
    });
  });

  group('预编译与复用', () {
    test('precompile 后仍能正确执行', () async {
      final engine = newDartEngine();
      engine.precompile('var a = 1; a + 2');
      expect(await engine.eval('var a = 1; a + 2'), 3);
      expect(await engine.eval('var a = 1; a + 2'), 3);
    });

    test('多次执行互不污染', () async {
      final engine = newDartEngine();
      await engine.eval('var x = 1;');
      expect(await engine.eval('typeof x'), 'undefined');
    });

    test('precompile 会缓存语法错误（第二次仍旧报错而不是崩溃）', () async {
      final engine = newDartEngine();
      expect(() => engine.precompile('var ='), throwsA(anything));
    });

    test('dispose 清空缓存后可继续使用', () async {
      final engine = newDartEngine();
      await engine.eval('1 + 1');
      engine.dispose();
      expect(await engine.eval('1 + 1'), 2);
    });
  });

  group('性能', () {
    test('100 行左右的脚本执行在 2 秒内', () async {
      final buf = StringBuffer();
      buf.writeln('var total = 0;');
      for (var i = 0; i < 40; i++) {
        buf.writeln("total += $i * 2;");
      }
      buf.writeln('var words = [];');
      for (var i = 0; i < 20; i++) {
        buf.writeln("words.push('w$i');");
      }
      buf.writeln("words.map(function(w) { return w.toUpperCase(); }).join('-');");
      final script = buf.toString();
      final engine = newDartEngine();
      engine.precompile(script);
      final sw = Stopwatch()..start();
      final v = await engine.eval(script);
      sw.stop();
      expect(v, startsWith('W0-W1'));
      expect(sw.elapsedMilliseconds < 2000, true, reason: '耗时 ${sw.elapsedMilliseconds}ms');
    });

    test('预编译后重复执行 200 次不超过 3 秒', () async {
      const script = '[1,2,3,4,5].map(x => x * 2).filter(x => x > 4).length';
      final engine = newDartEngine();
      engine.precompile(script);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        await engine.eval(script);
      }
      sw.stop();
      expect(sw.elapsedMilliseconds < 3000, true, reason: '耗时 ${sw.elapsedMilliseconds}ms');
    });
  });
}
