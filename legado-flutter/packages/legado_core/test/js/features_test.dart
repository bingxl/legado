import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('字面量细节', () {
    test('十六进制 / 前导小数点 / 科学计数', () async {
      expect(await run('[0xff, .5, 1e3, 1.5e-2]'), [255, 0.5, 1000, 0.015]);
    });

    test('转义序列', () async {
      expect(await run(r"""'\u4e2d\n\t\"'"""), '中\n\t"');
      expect(await run(r"'\x41'"), 'A');
    });

    test('模板字符串插值与嵌套', () async {
      expect(await run(r'var a = 2; `x${a + 1}y${`z${a}`}`'), 'x3yz2');
    });

    test('多行模板字符串', () async {
      final v = await run('`a\nb`');
      expect(v, 'a\nb');
    });

    test('字符串里出现正则元字符不误判', () async {
      expect(await run(r"'a/b'.split('/')"), ['a', 'b']);
    });
  });

  group('表达式细节', () {
    test('IIFE', () async {
      expect(await run('(function(){ return 42; })()'), 42);
    });

    test('链式三元', () async {
      expect(
        await run("var n = 2; n === 1 ? 'a' : n === 2 ? 'b' : 'c'"),
        'b',
      );
    });

    test('可选链下标', () async {
      expect(await run("var m = 'x7'.match(/(\\d)/); m?.[1]"), '7');
      expect(await run('var m = null; m?.[0]'), null);
    });

    test('函数调用链', () async {
      expect(await run("'  a,b  '.trim().split(',').map(s => s.toUpperCase()).join('-')"), 'A-B');
    });

    test('对象方法链', () async {
      expect(
        await run('''
          function Box(v) { return {v: v, add: function(x) { this.v += x; return this; }}; }
          Box(1).add(2).add(3).v;
        '''),
        6,
      );
    });

    test('new Array 与 join', () async {
      expect(await run("new Array(3).join('-')"), '--');
      expect(await run('Array(3).length'), 3);
      expect(await run('new Array(1, 2)'), [1, 2]);
    });

    test('数字 toString(radix)', () async {
      expect(await run('(255).toString(16)'), 'ff');
      expect(await run('(5).toString(2)'), '101');
    });

    test('codePointAt / fromCodePoint', () async {
      expect(await run("'A'.codePointAt(0)"), 65);
      expect(await run('String.fromCodePoint(65)'), 'A');
    });

    test('数组 fill', () async {
      expect(await run('[1,2,3].fill(0, 1)'), [1, 0, 0]);
    });
  });

  group('字符串化约定', () {
    test('String 各种入参', () async {
      expect(await run('[String(null), String(1.5), String(true), String([])]'), [
        'null',
        '1.5',
        'true',
        '',
      ]);
    });

    test('Boolean 各种入参', () async {
      expect(await run("[Boolean(''), Boolean('0'), Boolean(0)]"), [false, true, false]);
    });

    test('数组转字符串用逗号', () async {
      expect(await run('String([1,[2,3]])'), '1,2,3');
    });

    test('函数转字符串', () async {
      final v = await run('String(function foo(){})') as String;
      expect(v, contains('function'));
    });
  });

  group('键与属性', () {
    test('数字键会被转成字符串', () async {
      expect(await run('var o = {}; o[1] = "a"; o["1"]'), 'a');
    });

    test('属性不存在返回 null', () async {
      expect(await run('({}).nope'), null);
      expect(await run('typeof ({}.nope)'), 'undefined');
    });

    test('数组下标越界返回 null', () async {
      expect(await run('[1][5]'), null);
    });

    test('负下标不命中', () async {
      expect(await run('[1,2][-1]'), null);
    });
  });

  group('正则高级', () {
    test('[\\s\\S] 匹配换行', () async {
      expect(await run(r"'a\nb'.replace(/[\s\S]/g, '.')"), '...');
    });

    test('非捕获组与量词', () async {
      expect(await run(r"'aaa'.match(/(?:a){2}/)[0]"), 'aa');
    });

    test('命名捕获组', () async {
      expect(await run(r"var m = /(?<y>\d{4})/.exec('x2024'); m[1]"), '2024');
    });

    test(r"replace 中 $` 与 $'", () async {
      expect(await run(r"'abc'.replace(/b/, '$`')"), 'aac');
      expect(await run(r"""'abc'.replace(/b/, "$'")"""), 'acc');
    });
  });
}
