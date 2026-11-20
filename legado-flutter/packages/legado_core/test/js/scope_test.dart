import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('var / let / const', () {
    test('var 是函数作用域，在块里赋值影响外层', () async {
      expect(await run('var a = 1; { var a = 2; } a'), 2);
    });

    test('let 是块作用域', () async {
      expect(await run('let a = 1; { let a = 2; } a'), 1);
    });

    test('const 不能重新赋值', () async {
      final e = await expectError('const a = 1; a = 2;');
      expect(e.toString(), contains('常量'));
    });

    test('let 可以重新赋值', () async {
      expect(await run('let a = 1; a = 2; a'), 2);
    });

    test('var 提升：声明前读到 null（值模型等价 undefined）', () async {
      expect(await run('typeof a; var a = 1;'), 'undefined');
      expect(await run('var a = a; a'), null);
    });

    test('多层遮蔽', () async {
      expect(
        await run('''
          var a = 1;
          function f() {
            var a = 2;
            { let a = 3; }
            return a;
          }
          [f(), a];
        '''),
        [2, 1],
      );
    });
  });

  group('循环中的闭包', () {
    test('let 每轮独立绑定', () async {
      expect(
        await run('''
          var fns = [];
          for (let i = 0; i < 3; i++) { fns.push(() => i); }
          [fns[0](), fns[1](), fns[2]()];
        '''),
        [0, 1, 2],
      );
    });

    test('var 共享同一绑定', () async {
      expect(
        await run('''
          var fns = [];
          for (var i = 0; i < 3; i++) { fns.push(() => i); }
          [fns[0](), fns[1](), fns[2]()];
        '''),
        [3, 3, 3],
      );
    });

    test('for...of 的 let 每轮独立', () async {
      expect(
        await run('''
          var fns = [];
          for (let x of [1, 2]) { fns.push(() => x); }
          [fns[0](), fns[1]()];
        '''),
        [1, 2],
      );
    });
  });

  group('作用域链', () {
    test('内层函数能读到外层变量', () async {
      expect(await run('var a = 10; function f() { return a; } f()'), 10);
    });

    test('函数参数遮蔽全局', () async {
      expect(await run('var a = 1; function f(a) { return a; } f(5)'), 5);
    });

    test('未声明直接赋值会挂到全局', () async {
      expect(await run('a = 7; a'), 7);
    });

    test('IIFE 不污染外层', () async {
      expect(await run('var a = 1; (function() { var a = 2; })(); a'), 1);
    });
  });
}
