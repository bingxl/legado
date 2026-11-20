import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('算术与优先级', () {
    test('乘法优先于加法', () async {
      expect(await run('1 + 2 * 3'), 7);
    });

    test('括号改变优先级', () async {
      expect(await run('(1 + 2) * 3'), 9);
    });

    test('除法产生小数', () async {
      expect(await run('1 / 2'), 0.5);
    });

    test('取模与乘方', () async {
      expect(await run('10 % 3'), 1);
      expect(await run('2 ** 10'), 1024);
      expect(await run('2 ** 3 ** 2'), 512);
    });

    test('一元运算', () async {
      expect(await run('-3 + +"2"'), -1);
      expect(await run('~5'), -6);
      expect(await run('!0'), true);
    });

    test('位运算', () async {
      expect(await run('5 & 3'), 1);
      expect(await run('5 | 3'), 7);
      expect(await run('5 ^ 3'), 6);
      expect(await run('1 << 4'), 16);
      expect(await run('16 >> 2'), 4);
    });

    test('自增自减前后缀', () async {
      expect(await run('var a = 1; var b = a++; [a, b]'), [2, 1]);
      expect(await run('var a = 1; var b = ++a; [a, b]'), [2, 2]);
      expect(await run('var a = 5; a--; a'), 4);
    });
  });

  group('比较', () {
    test('严格相等不转换类型', () async {
      expect(await run("1 === '1'"), false);
      expect(await run('1 === 1.0'), true);
      // 解释器把 undefined 建模成 null；真 JS 是 null === undefined → false。
      if (dartEngine) expect(await run('null === undefined'), true);
    });

    test('宽松相等做类型转换', () async {
      expect(await run("1 == '1'"), true);
      expect(await run('0 == false'), true);
      expect(await run("'' == 0"), true);
      expect(await run('null == 0'), false);
    });

    test('字符串比较', () async {
      expect(await run("'a' < 'b'"), true);
      expect(await run("'10' < '9'"), true);
      expect(await run("'10' < 9"), false);
    });
  });

  group('逻辑', () {
    test('&& 返回原值并短路', () async {
      expect(await run("1 && 'x'"), 'x');
      expect(await run("0 && 'x'"), 0);
      expect(await run('var n = 0; false && (n = 1); n'), 0);
    });

    test('|| 返回原值并短路', () async {
      expect(await run("'' || 'fallback'"), 'fallback');
      expect(await run("'a' || 'b'"), 'a');
      expect(await run('var n = 0; true || (n = 1); n'), 0);
    });

    test('?? 只处理 null/undefined', () async {
      expect(await run('null ?? 5'), 5);
      expect(await run('0 ?? 5'), 0);
      expect(await run("'' ?? 'x'"), '');
    });

    test('优先级 a && b || c', () async {
      expect(await run('true && false || true'), true);
      expect(await run('false || true && false'), false);
    });
  });

  group('三元与逗号', () {
    test('三元', () async {
      expect(await run("1 > 2 ? 'a' : 'b'"), 'b');
      expect(await run('true ? 1 : false ? 2 : 3'), 1);
    });

    test('逗号运算符返回最后一个', () async {
      expect(await run('var a = (1, 2, 3); a'), 3);
    });
  });

  group('typeof / instanceof / in / delete / void', () {
    test('typeof', () async {
      expect(await run("typeof 1"), 'number');
      expect(await run("typeof 's'"), 'string');
      expect(await run('typeof {}'), 'object');
      expect(await run('typeof []'), 'object');
      expect(await run('typeof function(){}'), 'function');
      expect(await run('typeof undefined'), 'undefined');
      expect(await run('typeof notDefinedVar'), 'undefined');
    });

    test('instanceof', () async {
      expect(await run('[] instanceof Array'), true);
      // 真 JS 里原始字符串不是 String 的实例（解释器把它当包装对象）。
      if (dartEngine) expect(await run("'x' instanceof String"), true);
      expect(await run('/a/ instanceof RegExp'), true);
    });

    test('in', () async {
      expect(await run("'a' in {a: 1}"), true);
      expect(await run("'b' in {a: 1}"), false);
      expect(await run('1 in [1, 2]'), true);
      expect(await run('5 in [1, 2]'), false);
    });

    test('delete 对象属性', () async {
      expect(await run('var o = {a: 1, b: 2}; delete o.a; JSON.stringify(o)'), '{"b":2}');
    });

    test('void 返回 undefined', () async {
      expect(await run('void 0'), null);
    });
  });

  group('字符串与数字混合', () {
    test('加法按字符串拼接', () async {
      expect(await run("'a' + 1 + 2"), 'a12');
      expect(await run("1 + 2 + 'a'"), '3a');
    });
  });
}
