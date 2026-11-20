import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('if / else', () {
    test('基本分支', () async {
      expect(await run("var x = 2; if (x > 1) { 'big'; } else { 'small'; }"), 'big');
    });

    test('else if 链', () async {
      expect(
        await run('''
          function grade(n) {
            if (n >= 90) return 'A';
            else if (n >= 60) return 'B';
            else return 'C';
          }
          grade(75);
        '''),
        'B',
      );
    });
  });

  group('循环', () {
    test('for 三段式', () async {
      expect(await run('var s = 0; for (var i = 1; i <= 5; i++) s += i; s'), 15);
    });

    test('while', () async {
      expect(await run('var n = 0; while (n < 3) n++; n'), 3);
    });

    test('do...while 至少执行一次', () async {
      expect(await run('var n = 0; do { n++; } while (false); n'), 1);
    });

    test('for...of 遍历数组', () async {
      expect(await run('var s = 0; for (var x of [1,2,3]) s += x; s'), 6);
    });

    test('for...in 遍历键', () async {
      expect(await run("var ks = []; for (var k in {a: 1, b: 2}) ks.push(k); ks"), ['a', 'b']);
    });

    test('break / continue', () async {
      expect(
        await run('var s = 0; for (var i = 0; i < 10; i++) { if (i === 5) break; if (i % 2 === 0) continue; s += i; } s'),
        4,
      );
    });

    test('标签 break', () async {
      expect(
        await run('''
          var out = '';
          outer:
          for (var i = 0; i < 3; i++) {
            for (var j = 0; j < 3; j++) {
              if (j === 2) break outer;
              out += i + '' + j;
            }
          }
          out;
        '''),
        '0001',
      );
    });
  });

  group('switch', () {
    test('命中与贯穿', () async {
      expect(
        await run('''
          function f(n) {
            var out = '';
            switch (n) {
              case 1:
                out += 'a';
              case 2:
                out += 'b';
                break;
              default:
                out += 'z';
            }
            return out;
          }
          [f(1), f(2), f(9)];
        '''),
        ['ab', 'b', 'z'],
      );
    });

    test('字符串 case', () async {
      expect(await run("var r = ''; switch ('x') { case 'x': r = 'hit'; break; } r"), 'hit');
    });
  });

  group('try / catch / finally', () {
    test('catch 捕获 throw', () async {
      expect(await run("var r = ''; try { throw 'boom'; } catch (e) { r = e; } r"), 'boom');
    });

    test('finally 一定执行（正常路径）', () async {
      expect(await run("var log = []; try { log.push('t'); } finally { log.push('f'); } log"), ['t', 'f']);
    });

    test('finally 一定执行（抛错路径）', () async {
      expect(
        await run('''
          var log = [];
          try {
            try { throw new Error('x'); } finally { log.push('inner'); }
          } catch (e) { log.push(e.message); }
          log;
        '''),
        ['inner', 'x'],
      );
    });

    test('return 时 finally 仍执行且不覆盖返回值', () async {
      expect(
        await run('''
          var log = [];
          function f() {
            try { return 1; } finally { log.push('finally'); }
          }
          var r = f();
          [r, log.length];
        '''),
        [1, 1],
      );
    });

    test('throw 任意值', () async {
      final e = await expectError('throw {code: 7}');
      expect(e.toString(), contains('未捕获'));
    });
  });

  group('语句细节', () {
    test('自动分号插入', () async {
      expect(await run('var a = 1\nvar b = 2\na + b'), 3);
    });

    test('空语句与块作用域', () async {
      expect(await run('var a = 1; { var a = 2; } a'), 2);
    });

    test('标签语句包普通块', () async {
      expect(await run("var r = ''; lbl: { r = 'x'; break lbl; r = 'y'; } r"), 'x');
    });
  });
}
