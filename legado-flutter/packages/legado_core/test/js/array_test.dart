import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('增删改', () {
    test('push / pop / shift / unshift', () async {
      expect(await run('var a = [1]; a.push(2, 3); a'), [1, 2, 3]);
      expect(await run('var a = [1, 2]; a.pop()'), 2);
      expect(await run('var a = [1, 2]; a.shift()'), 1);
      expect(await run('var a = [2]; a.unshift(0, 1); a'), [0, 1, 2]);
    });

    test('splice 删除与插入', () async {
      expect(await run('var a = [1,2,3,4]; var r = a.splice(1, 2, 9); [a, r]'), [
        [1, 9, 4],
        [2, 3],
      ]);
    });

    test('length 可写', () async {
      expect(await run('var a = [1,2,3]; a.length = 2; a'), [1, 2]);
      expect(await run('var a = [1]; a.length = 3; a'), [1, null, null]);
    });
  });

  group('查找与切片', () {
    test('slice / concat', () async {
      expect(await run('[1,2,3,4].slice(1, 3)'), [2, 3]);
      expect(await run('[1,2,3].slice(-2)'), [2, 3]);
      expect(await run('[1].concat([2, 3], 4)'), [1, 2, 3, 4]);
    });

    test('indexOf / includes', () async {
      expect(await run("[1,2,3].indexOf(2)"), 1);
      expect(await run("[1,2,3].indexOf('2')"), -1);
      expect(await run('[1,2,3].includes(3)'), true);
    });

    test('join', () async {
      expect(await run("[1,2,3].join('-')"), '1-2-3');
      expect(await run('[1,null,3].join()'), '1,,3');
    });

    test('reverse 原地', () async {
      expect(await run('var a = [1,2,3]; a.reverse(); a'), [3, 2, 1]);
    });
  });

  group('排序', () {
    test('默认按字符串排序', () async {
      expect(await run('[10, 2, 1].sort()'), [1, 10, 2]);
    });

    test('比较函数按数字排序', () async {
      expect(await run('[10, 2, 1].sort(function(a, b){ return a - b; })'), [1, 2, 10]);
      expect(await run('[10, 2, 1].sort((a, b) => b - a)'), [10, 2, 1]);
    });
  });

  group('高阶函数', () {
    test('map / filter 链式调用', () async {
      expect(
        await run('[1,2,3,4,5].filter(x => x % 2 === 1).map(x => x * x)'),
        [1, 9, 25],
      );
    });

    test('forEach 累加', () async {
      expect(await run('var s = 0; [1,2,3].forEach((v, i) => s += v * i); s'), 8);
    });

    test('reduce 带初始值', () async {
      expect(await run('[1,2,3].reduce((a, b) => a + b, 10)'), 16);
    });

    test('reduce 不带初始值', () async {
      expect(await run("['a','b','c'].reduce((a, b) => a + b)"), 'abc');
    });

    test('find / findIndex / some / every', () async {
      expect(await run('[1,2,3].find(x => x > 1)'), 2);
      expect(await run('[1,2,3].findIndex(x => x > 5)'), -1);
      expect(await run('[1,2,3].some(x => x === 2)'), true);
      expect(await run('[1,2,3].every(x => x > 0)'), true);
    });

    test('flat / flatMap', () async {
      expect(await run('[1,[2,[3]]].flat()'), [1, 2, [3]]);
      expect(await run('[1,[2,[3]]].flat(2)'), [1, 2, 3]);
      expect(await run('[1,2].flatMap(x => [x, x * 10])'), [1, 10, 2, 20]);
    });

    test('回调里能拿到 index 与数组本身', () async {
      expect(await run('[10,20].map((v, i, arr) => v + i + arr.length)'), [12, 23]);
    });
  });

  group('数组字面量', () {
    test('展开语法', () async {
      expect(await run('var a = [2,3]; [1, ...a, 4]'), [1, 2, 3, 4]);
    });

    test('空位视为 null', () async {
      expect(await run('var a = [1, , 3]; [a.length, a[1]]'), [3, null]);
    });
  });
}
