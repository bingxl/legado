import 'package:legado_core/src/net/source_rate_gate.dart';
import 'package:test/test.dart';

void main() {
  group('SourceRateGate.parse', () {
    test('空串 / 0 / 非法值视为不限速', () {
      expect(SourceRateGate.parse(null), isNull);
      expect(SourceRateGate.parse(''), isNull);
      expect(SourceRateGate.parse('  '), isNull);
      expect(SourceRateGate.parse('0'), isNull);
      expect(SourceRateGate.parse('0/1000'), isNull);
      expect(SourceRateGate.parse('3/0'), isNull);
      expect(SourceRateGate.parse('abc'), isNull);
      expect(SourceRateGate.parse('3/abc'), isNull);
    });

    test('单个数字是最小间隔（串行）', () {
      final gate = SourceRateGate.parse('1500')!;
      expect(gate.maxPerWindow, 1);
      expect(gate.window, const Duration(milliseconds: 1500));
    });

    test('次数/毫秒是窗口限流', () {
      final gate = SourceRateGate.parse('3/1000')!;
      expect(gate.maxPerWindow, 3);
      expect(gate.window, const Duration(milliseconds: 1000));
    });
  });

  group('SourceRateGate', () {
    test('窗口内未超限时不等待', () async {
      final gate = SourceRateGate.parse('3/200')!;
      final sw = Stopwatch()..start();
      await gate.acquire();
      await gate.acquire();
      await gate.acquire();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(80));
    });

    test('超限后等到窗口滑动才放行', () async {
      final gate = SourceRateGate.parse('2/120')!;
      await gate.acquire();
      await gate.acquire();
      final sw = Stopwatch()..start();
      await gate.acquire();
      sw.stop();
      // 第三个请求必须等第一个滑出窗口（≈120ms），留点余量给调度抖动。
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(70));
    });

    test('run 包住动作并在动作完成后不影响后续计数', () async {
      final gate = SourceRateGate.parse('5/500')!;
      var ran = 0;
      for (var i = 0; i < 5; i++) {
        await gate.run(() async {
          ran++;
        });
      }
      expect(ran, 5);
    });
  });

  group('SourceRateGateRegistry', () {
    test('同一书源同一配置复用闸门', () {
      final registry = SourceRateGateRegistry();
      final a = registry.gateOf('https://a.test', '3/1000');
      final b = registry.gateOf('https://a.test', '3/1000');
      expect(identical(a, b), isTrue);
    });

    test('书源改限速后换新闸门，不同书源互不影响', () {
      final registry = SourceRateGateRegistry();
      final a = registry.gateOf('https://a.test', '3/1000');
      final changed = registry.gateOf('https://a.test', '1/500');
      expect(identical(a, changed), isFalse);
      expect(changed!.maxPerWindow, 1);
      final other = registry.gateOf('https://b.test', '3/1000');
      expect(identical(other, changed), isFalse);
      expect(registry.gateOf('https://c.test', null), isNull);
    });
  });
}
