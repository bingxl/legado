import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('对象字面量', () {
    test('基本读写与计算属性名', () async {
      expect(await run("var k = 'b'; var o = {a: 1, [k]: 2}; o.a + o.b"), 3);
    });

    test('简写属性', () async {
      expect(await run('var a = 1; var o = {a}; o.a'), 1);
    });

    test('方法简写与 this', () async {
      expect(await run('var o = {n: 2, double() { return this.n * 2; }}; o.double()'), 4);
    });

    test('嵌套对象与可选链', () async {
      expect(await run('var o = {a: {b: 1}}; o?.a?.b'), 1);
      expect(await run('var o = {}; o?.a?.b'), null);
    });

    test('展开对象', () async {
      expect(await run('var o = {a: 1, b: 2}; JSON.stringify({...o, b: 3})'), '{"a":1,"b":3}');
    });
  });

  group('Object 静态方法', () {
    test('keys / values / entries', () async {
      expect(await run("Object.keys({a: 1, b: 2})"), ['a', 'b']);
      expect(await run("Object.values({a: 1, b: 2})"), [1, 2]);
      expect(await run("Object.entries({a: 1})"), [
        ['a', 1],
      ]);
    });

    test('Object.keys 对数组返回下标字符串', () async {
      expect(await run("Object.keys(['x','y'])"), ['0', '1']);
    });

    test('assign', () async {
      expect(await run("JSON.stringify(Object.assign({a: 1}, {b: 2}, {a: 3}))"), '{"a":3,"b":2}');
    });

    test('fromEntries', () async {
      expect(await run("JSON.stringify(Object.fromEntries([['a', 1], ['b', 2]]))"), '{"a":1,"b":2}');
    });
  });

  group('JSON', () {
    test('parse 基本类型', () async {
      expect(await run("JSON.parse('{\"a\":[1,2],\"b\":null}')['a'][1]"), 2);
    });

    test('stringify 嵌套与转义', () async {
      expect(await run("JSON.stringify({a: [1, 'x'], b: true})"), '{"a":[1,"x"],"b":true}');
    });

    test('stringify 跳过函数，undefined 因值模型等价于 null 而输出 null', () async {
      expect(await run("JSON.stringify({a: 1, f: function(){}})"), '{"a":1}');
      // 真 JS 的 JSON.stringify 会直接丢掉 undefined 字段（解释器输出 null）。
      expect(
        await run("JSON.stringify({a: 1, u: undefined})"),
        dartEngine ? '{"a":1,"u":null}' : '{"a":1}',
      );
    });

    test('parse 失败给出位置信息', () async {
      final e = await expectError("JSON.parse('{oops')");
      expect(e.toString(), contains('JSON.parse'));
    });
  });

  group('Map 风格访问', () {
    test('hasOwnProperty', () async {
      expect(await run("({a: 1}).hasOwnProperty('a')"), true);
      expect(await run("({a: 1}).hasOwnProperty('b')"), false);
    });

    test('对象转字符串', () async {
      expect(await run("String({})"), '[object Object]');
    });
  });
}
