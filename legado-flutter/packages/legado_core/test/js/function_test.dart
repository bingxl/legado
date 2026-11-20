import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('函数声明与表达式', () {
    test('声明提升', () async {
      expect(await run('f(2); function f(x) { return x * 3; }'), 6);
    });

    test('函数表达式', () async {
      expect(await run('var f = function(a, b) { return a + b; }; f(1, 2)'), 3);
    });

    test('默认参数', () async {
      expect(await run('function f(a, b = 10) { return a + b; } f(1)'), 11);
      expect(await run('function f(a, b = 10) { return a + b; } f(1, 2)'), 3);
    });

    test('剩余参数', () async {
      expect(await run('function f(a, ...rest) { return [a, rest.length, rest[0]]; } f(1, 2, 3)'), [
        1,
        2,
        2,
      ]);
    });

    test('arguments 对象', () async {
      expect(await run('function f() { return arguments.length + arguments[0]; } f(5, 6)'), 7);
    });

    test('递归', () async {
      expect(await run('function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); } fib(10)'), 55);
    });
  });

  group('箭头函数', () {
    test('单参数免括号', () async {
      expect(await run('[1,2,3].map(x => x * 2)'), [2, 4, 6]);
    });

    test('表达式体返回对象需要括号', () async {
      expect(await run('var f = x => ({v: x}); f(7).v'), 7);
    });

    test('块体需要 return', () async {
      expect(await run('var f = (a, b) => { var c = a + b; return c * 2; }; f(1, 2)'), 6);
    });

    test('箭头函数捕获外层 this', () async {
      expect(
        await run('''
          var o = {
            n: 5,
            f: function() {
              var g = () => this.n;
              return g();
            }
          };
          o.f();
        '''),
        5,
      );
    });
  });

  group('闭包与高阶函数', () {
    test('计数器闭包', () async {
      expect(
        await run('''
          function counter() {
            var n = 0;
            return function() { n += 1; return n; };
          }
          var c = counter();
          c(); c(); c();
        '''),
        3,
      );
    });

    test('函数作为参数与返回值', () async {
      expect(
        await run('''
          function twice(f) { return function(x) { return f(f(x)); }; }
          twice(function(x) { return x + 3; })(1);
        '''),
        7,
      );
    });

    test('apply / call', () async {
      expect(await run("function f(a){ return this.n + a; } f.call({n: 1}, 2)"), 3);
      expect(await run("function f(a){ return this.n + a; } f.apply({n: 1}, [2])"), 3);
    });

    test('bind', () async {
      expect(await run('function f(a){ return this.n + a; } var g = f.bind({n: 10}); g(5)'), 15);
    });
  });

  group('this', () {
    test('普通函数调用 this 为 undefined', () async {
      expect(await run('var f = function() { return this; }; f() === undefined'), true);
    }, skip: dartOnly);

    test('方法调用 this 指向对象', () async {
      expect(await run('var o = {n: 1, f: function() { return this.n; }}; o.f()'), 1);
    });
  });
}
