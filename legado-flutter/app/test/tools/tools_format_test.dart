import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/tools/tools_format.dart';

void main() {
  group('formatBytes', () {
    test('字节以内取整，不做小数', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-1), '0 B');
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
    });

    test('KB / MB / GB 保留一位小数', () {
      expect(formatBytes(1024), '1.0 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(1024 * 1024), '1.0 MB');
      // 契约里的示例：1048576 → 1.0 MB，1258291 → 1.2 MB
      expect(formatBytes(1258291), '1.2 MB');
      expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
      expect(formatBytes(1024 * 1024 * 1024 * 3 ~/ 2), '1.5 GB');
    });

    test('超过 GB 也停在 GB，不再升档', () {
      expect(formatBytes(1024 * 1024 * 1024 * 2048), '2048.0 GB');
    });
  });

  group('parseTime', () {
    test('RFC3339 带时区', () {
      final t = parseTime('2026-05-01T10:00:00+08:00');
      expect(t, isNotNull);
      // 解析后统一转成本地时间，比较时刻即可。
      expect(t!.toUtc(), DateTime.utc(2026, 5, 1, 2, 0, 0));
    });

    test('脏数据不抛异常', () {
      expect(parseTime(null), isNull);
      expect(parseTime(''), isNull);
      expect(parseTime('not-a-time'), isNull);
      expect(parseTime(0), isNull);
      expect(parseTime(-5), isNull);
    });

    test('兼容 unix 秒', () {
      expect(
        parseTime(1746064800)?.toUtc(),
        DateTime.fromMillisecondsSinceEpoch(1746064800 * 1000, isUtc: true),
      );
    });
  });

  group('dayLabel', () {
    final now = DateTime(2026, 5, 18, 9, 30);

    test('今天 / 昨天 / 具体日期', () {
      expect(dayLabel(DateTime(2026, 5, 18, 1), now: now), '今天');
      expect(dayLabel(DateTime(2026, 5, 17, 23, 59), now: now), '昨天');
      expect(dayLabel(DateTime(2026, 5, 1, 10), now: now), '2026-05-01');
      expect(dayLabel(DateTime(2025, 12, 31), now: now), '2025-12-31');
    });

    test('跨月/跨年的昨天也认得出来', () {
      expect(dayLabel(DateTime(2026, 4, 30), now: DateTime(2026, 5, 1)), '昨天');
      expect(dayLabel(DateTime(2025, 12, 31), now: DateTime(2026, 1, 1)), '昨天');
    });
  });

  group('formatClock / formatDateTime', () {
    test('分钟补零', () {
      expect(formatClock(DateTime(2026, 5, 1, 8, 5)), '08:05');
      expect(formatClock(DateTime(2026, 5, 1, 23, 59)), '23:59');
      expect(formatDateTime(DateTime(2026, 5, 1, 8, 5)), '2026-05-01 08:05');
    });
  });

  group('groupByDay', () {
    test('保持入参顺序，同日归到一组', () {
      final now = DateTime(2026, 5, 18, 12);
      final items = <String>['a', 'b', 'c', 'd'];
      final times = <String, DateTime?>{
        'a': DateTime(2026, 5, 18, 9),
        'b': DateTime(2026, 5, 18, 8),
        'c': DateTime(2026, 5, 17, 20),
        'd': DateTime(2026, 5, 1, 7),
      };
      final groups = groupByDay(items, (it) => times[it], now: now);
      expect(groups.map((g) => g.label).toList(), ['今天', '昨天', '2026-05-01']);
      expect(groups[0].items, ['a', 'b']);
      expect(groups[2].items, ['d']);
    });

    test('缺时间的条目归到「未知时间」并垫底', () {
      final now = DateTime(2026, 5, 18, 12);
      final items = <String>['bad', 'today'];
      final times = <String, DateTime?>{
        'bad': null,
        'today': DateTime(2026, 5, 18, 10),
      };
      final groups = groupByDay(items, (it) => times[it], now: now);
      expect(groups.map((g) => g.label).toList(), ['今天', unknownDayLabel]);
      expect(groups.last.items, ['bad']);
    });

    test('空列表返回空分组', () {
      expect(groupByDay<int>(const [], (it) => null), isEmpty);
    });
  });

  group('cacheProgress', () {
    test('(done+failed)/total，失败章节也算处理过', () {
      expect(cacheProgress(0, 0, 10), 0);
      expect(cacheProgress(5, 0, 10), 0.5);
      expect(cacheProgress(5, 2, 10), 0.7);
      expect(cacheProgress(10, 0, 10), 1);
    });

    test('total 非法时退化为 0，不产生 NaN', () {
      expect(cacheProgress(0, 0, 0), 0);
      expect(cacheProgress(3, 0, -1), 0);
    });

    test('超额进度被夹到 1', () {
      expect(cacheProgress(20, 0, 10), 1);
    });

    test('进度文案带分母', () {
      expect(cacheProgressLabel(5, 2, 10), '7/10');
      expect(cacheProgressLabel(0, 0, 0), '0/0');
    });
  });
}
