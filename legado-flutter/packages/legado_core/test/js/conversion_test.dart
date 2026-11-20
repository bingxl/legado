import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('加法类型转换表', () {
    test("'1' + 1", () async {
      expect(await run("'1' + 1"), '11');
    });

    test("1 + '1'", () async {
      expect(await run("1 + '1'"), '11');
    });

    test("'2' * '3'", () async {
      expect(await run("'2' * '3'"), 6);
    });

    test('null + 1', () async {
      expect(await run('null + 1'), 1);
    });

    test('undefined 在值模型中等价于 null', () async {
      // 解释器把 undefined 当成 null（缺失字段与空字段一样处理）；
      // 真 JS 里 undefined != null，undefined + 1 是 NaN。
      expect(await run('undefined == null'), true);
      expect(await run('undefined + 1'), 1);
      expect(await run('String(undefined)'), 'null');
    }, skip: dartOnly);

    test('[] + {}', () async {
      expect(await run('[] + {}'), '[object Object]');
    });

    test('[1,2] + 3', () async {
      expect(await run('[1,2] + 3'), '1,23');
    });
  });

  group('真值转换', () {
    test('!! 空串、0、null、NaN 为 false', () async {
      expect(await run("!!''"), false);
      expect(await run('!!0'), false);
      expect(await run('!!null'), false);
      expect(await run('!!NaN'), false);
      expect(await run("!!'0'"), true);
      expect(await run('!![]'), true);
      expect(await run('!!{}'), true);
    });
  });

  group('数字转字符串', () {
    test('整数不带小数点', () async {
      expect(await run('String(1.0)'), '1');
      expect(await run('(1.5).toString()'), '1.5');
    });

    test('NaN / Infinity', () async {
      expect(await run('String(NaN)'), 'NaN');
      expect(await run('String(Infinity)'), 'Infinity');
    });

    test('parseInt / parseFloat', () async {
      expect(await run("parseInt('42px')"), 42);
      expect(await run("parseInt('ff', 16)"), 255);
      expect(await run("parseInt('0x10')"), 16);
      expect(await run("parseFloat('3.14abc')"), 3.14);
      expect((await run("parseInt('abc')") as num).isNaN, true);
    });

    test('toFixed', () async {
      expect(await run('(1.2345).toFixed(2)'), '1.23');
      expect(await run('(1).toFixed(2)'), '1.00');
    });

    test('Number 与 isNaN', () async {
      expect(await run("Number('12')"), 12);
      expect(await run("Number('')"), 0);
      expect(await run('Number(true)'), 1);
      expect(await run("isNaN('x')"), true);
      expect(await run("isNaN('12')"), false);
    });
  });

  group('字符串转数字', () {
    test('Number 十六进制与空串', () async {
      expect(await run("Number('0x1f')"), 31);
      expect(await run("Number(' ')"), 0);
      expect(await run("+'3.5'"), 3.5);
    });
  });

  group('布尔参与运算', () {
    test('true + true', () async {
      expect(await run('true + true'), 2);
    });

    test('布尔比较', () async {
      expect(await run('true == 1'), true);
      expect(await run('true === 1'), false);
    });
  });
}
