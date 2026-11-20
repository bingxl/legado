import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('查找与判断', () {
    test('indexOf / lastIndexOf', () async {
      expect(await run("'abcabc'.indexOf('bc')"), 1);
      expect(await run("'abcabc'.lastIndexOf('bc')"), 4);
      expect(await run("'abc'.indexOf('z')"), -1);
    });

    test('includes / startsWith / endsWith', () async {
      expect(await run("'hello'.includes('ell')"), true);
      expect(await run("'hello'.startsWith('he')"), true);
      expect(await run("'hello'.endsWith('lo')"), true);
      expect(await run("'hello'.startsWith('lo', 3)"), true);
    });

    test('charAt / charCodeAt / at', () async {
      expect(await run("'hello'.charAt(1)"), 'e');
      expect(await run("'hello'.charAt(99)"), '');
      expect(await run("'A'.charCodeAt(0)"), 65);
      expect(await run("'hello'.at(-1)"), 'o');
    });
  });

  group('截取', () {
    test('slice 支持负下标', () async {
      expect(await run("'abcdef'.slice(1, 3)"), 'bc');
      expect(await run("'abcdef'.slice(-2)"), 'ef');
    });

    test('substring 会交换并截断', () async {
      expect(await run("'abcdef'.substring(3, 1)"), 'bc');
      expect(await run("'abcdef'.substring(-2, 3)"), 'abc');
    });

    test('substr', () async {
      expect(await run("'abcdef'.substr(1, 3)"), 'bcd');
      expect(await run("'abcdef'.substr(-2)"), 'ef');
    });
  });

  group('变换', () {
    test('大小写与 trim', () async {
      expect(await run("'aBc'.toUpperCase()"), 'ABC');
      expect(await run("'aBc'.toLowerCase()"), 'abc');
      expect(await run("'  x  '.trim()"), 'x');
      expect(await run("'  x'.trimStart()"), 'x');
    });

    test('padStart / padEnd', () async {
      expect(await run("'7'.padStart(3, '0')"), '007');
      expect(await run("'7'.padEnd(3, 'ab')"), '7ab');
    });

    test('repeat 与 concat', () async {
      expect(await run("'ab'.repeat(3)"), 'ababab');
      expect(await run("'a'.concat('b', 1)"), 'ab1');
    });

    test('localeCompare', () async {
      expect(await run("'a'.localeCompare('b')"), -1);
    });
  });

  group('split', () {
    test('普通分隔符', () async {
      expect(await run("'a,b,c'.split(',')"), ['a', 'b', 'c']);
    });

    test('空分隔符切成字符', () async {
      expect(await run("'abc'.split('')"), ['a', 'b', 'c']);
    });

    test('正则分隔符', () async {
      expect(await run(r"'a1b2c'.split(/\d/)"), ['a', 'b', 'c']);
    });

    test('limit 限制结果数', () async {
      expect(await run("'a,b,c'.split(',', 2)"), ['a', 'b']);
    });
  });

  group('replace', () {
    test('字符串只替换第一处', () async {
      expect(await run("'aaa'.replace('a', 'b')"), 'baa');
    });

    test('replaceAll 替换全部', () async {
      expect(await run("'aaa'.replaceAll('a', 'b')"), 'bbb');
    });

    test('正则 g 标志替换全部', () async {
      expect(await run("'a1b2'.replace(/\\d/g, '#')"), 'a#b#');
    });

    test(r'$1 与 $& 捕获组', () async {
      expect(await run(r"'2024-01-02'.replace(/(\d+)-(\d+)-(\d+)/, '$3/$2/$1')"), '02/01/2024');
      expect(await run(r"'abc'.replace(/b/, '[$&]')"), 'a[b]c');
    });

    test('函数替换', () async {
      expect(await run("'a1b2'.replace(/\\d/g, function(m){ return String(Number(m) * 2); })"), 'a2b4');
    });

    test('函数替换拿到 offset 与整串', () async {
      expect(
        await run("'ab'.replace('b', function(m, offset, s){ return m + offset + s.length; })"),
        'ab12',
      );
    });

    test('replaceAll 对正则也生效', () async {
      expect(await run("'a1b2'.replaceAll(/\\d/, '#')"), 'a#b#');
    });
  });

  group('match / search', () {
    test('非全局 match 返回带 index 的数组', () async {
      expect(await run("var m = 'a1b'.match(/(\\d)/); [m[0], m[1], m.index]"), ['1', '1', 1]);
    });

    test('全局 match 返回所有匹配', () async {
      expect(await run("'a1b2'.match(/\\d/g)"), ['1', '2']);
    });

    test('无匹配返回 null', () async {
      expect(await run("'abc'.match(/\\d/)"), null);
    });

    test('search 返回下标', () async {
      expect(await run("'abc1'.search(/\\d/)"), 3);
    });
  });
}
