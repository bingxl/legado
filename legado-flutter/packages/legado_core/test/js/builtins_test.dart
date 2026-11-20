import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  group('Math', () {
    test('取整', () async {
      expect(await run('[Math.floor(1.7), Math.ceil(1.1), Math.round(1.5), Math.trunc(-1.7)]'), [1, 2, 2, -1]);
      expect(await run('Math.round(-1.5)'), -1);
    });

    test('min / max / abs / pow / sqrt', () async {
      expect(await run('[Math.min(3, 1, 2), Math.max(3, 1, 2)]'), [1, 3]);
      expect(await run('[Math.abs(-4), Math.pow(2, 8), Math.sqrt(81)]'), [4, 256, 9]);
    });

    test('random 在 [0,1)', () async {
      final v = await run('Math.random()') as num;
      expect(v >= 0 && v < 1, true);
    });

    test('常量', () async {
      final v = await run('Math.PI') as num;
      expect(v, closeTo(3.14159, 0.001));
    });
  });

  group('Number', () {
    test('静态判断', () async {
      expect(await run('[Number.isInteger(3), Number.isInteger(3.5), Number.isFinite(1)]'), [true, false, true]);
      expect(await run('Number.isNaN(NaN)'), true);
    });

    test('Number.parseInt', () async {
      expect(await run("Number.parseInt('101', 2)"), 5);
    });
  });

  group('Date', () {
    test('now 是毫秒时间戳', () async {
      final v = await run('Date.now()') as int;
      expect(v > 1600000000000, true);
    });

    test('new Date(ms) 的取值', () async {
      expect(
        await run('var d = new Date(1700000000000); [d.getFullYear(), d.getTime()]'),
        [2023, 1700000000000],
      );
    });

    test('toISOString 是 UTC', () async {
      expect(await run('new Date(0).toISOString()'), '1970-01-01T00:00:00.000Z');
    });
  });

  group('编码', () {
    test('encodeURIComponent / decodeURIComponent', () async {
      expect(await run("encodeURIComponent('a b&c')"), 'a%20b%26c');
      expect(await run("decodeURIComponent('a%20b')"), 'a b');
      expect(await run("encodeURIComponent('中文')"), '%E4%B8%AD%E6%96%87');
    });

    test('escape / unescape', () async {
      expect(await run("escape('a b')"), 'a%20b');
      expect(await run("unescape('a%20b')"), 'a b');
    });

    test('btoa / atob', () async {
      expect(await run("btoa('abc')"), 'YWJj');
      expect(await run("atob('YWJj')"), 'abc');
    });
  });

  group('其他全局', () {
    test('String.fromCharCode', () async {
      expect(await run('String.fromCharCode(65, 66)'), 'AB');
    });

    test('Array.isArray', () async {
      expect(await run('[Array.isArray([]), Array.isArray({})]'), [true, false]);
    });

    test('console.log 进入日志通道', () async {
      final logs = <String>[];
      final engine = newEngine(onLog: (level, msg) => logs.add('$level:$msg'));
      await engine.eval("console.log('a', 1, true)");
      expect(logs, ['info:a 1 true']);
    });

    test('print 也进入日志通道', () async {
      final logs = <String>[];
      final engine = newEngine(onLog: (level, msg) => logs.add(msg));
      await engine.eval("print('hello')");
      expect(logs, ['hello']);
    });
  });
}
