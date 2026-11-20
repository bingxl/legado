import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('正则字面量与除法歧义', () {
    test('字面量 test', () async {
      expect(await run(r'/^\d+$/.test("123")'), true);
      expect(await run(r'/^\d+$/.test("12a")'), false);
    });

    test('a = 1/2 是除法', () async {
      expect(await run('var a = 1 / 2; a'), 0.5);
    });

    test('a = /re/.test(s) 是正则', () async {
      expect(await run("var s = 'abc'; var a = /b/.test(s); a"), true);
    });

    test('先除法后正则', () async {
      expect(await run("var x = 10 / 2; var y = /5/.test('x5x'); [x, y]"), [5, true]);
    });

    test('字符类里的斜杠', () async {
      expect(await run(r"/[/]/.test('/')"), true);
    });
  });

  group('exec', () {
    test('非全局 exec 返回捕获组与 index', () async {
      expect(
        await run("var m = /(\\w+)-(\\w+)/.exec('a-b'); [m[0], m[1], m[2], m.index]"),
        ['a-b', 'a', 'b', 0],
      );
    });

    test('全局 exec 用 lastIndex 迭代', () async {
      const script = '''
        var re = /\\d+/g;
        var out = [];
        var m;
        while ((m = re.exec('a1b22c333')) !== null) {
          out.push(m[0]);
        }
        out;
      ''';
      expect(await run(script), ['1', '22', '333']);
    });

    test('无匹配返回 null', () async {
      expect(await run("/x/.exec('abc')"), null);
    });

    test('source 与 global 属性', () async {
      expect(await run('var re = /a+/g; [re.source, re.global, re.ignoreCase]'), ['a+', true, false]);
    });
  });

  group('动态构造', () {
    test('new RegExp', () async {
      expect(await run("new RegExp('a.c', 'i').test('AbC')"), true);
    });

    test('RegExp 作为函数', () async {
      expect(await run("RegExp('\\\\d').test('5')"), true);
    });
  });

  group('字符串配合正则', () {
    test('split 带捕获组', () async {
      expect(await run(r"'a1b2'.split(/(\d)/)"), ['a', '1', 'b', '2', '']);
    });

    test('search 与 match 全局', () async {
      expect(await run("'aXbXc'.match(/X/g)"), ['X', 'X']);
      expect(await run("'abc'.search(/c/)"), 2);
    });

    test('test 与 g 标志会推进 lastIndex', () async {
      expect(await run("var re = /a/g; [re.test('aa'), re.lastIndex]"), [true, 1]);
    });
  });
}
