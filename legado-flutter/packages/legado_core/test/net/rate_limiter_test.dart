import 'dart:async';

import 'package:legado_core/src/net/rate_limiter.dart';
import 'package:test/test.dart';

void main() {
  test('同一 host 并发不超过上限', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 3,
      minInterval: Duration.zero,
      globalConcurrency: 32,
    );
    var active = 0;
    var peak = 0;
    final tasks = List.generate(9, (_) {
      return limiter.run('a.com', () async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        active--;
      });
    });
    await Future.wait(tasks);
    expect(peak, lessThanOrEqualTo(3));
    expect(peak, greaterThanOrEqualTo(2), reason: '限流不该退化成串行');
    limiter.close();
  });

  test('不同 host 之间互不占用配额', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 1,
      minInterval: Duration.zero,
      globalConcurrency: 8,
    );
    final sw = Stopwatch()..start();
    await Future.wait([
      limiter.run(
        'a.com',
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      ),
      limiter.run(
        'b.com',
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      ),
    ]);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(230), reason: '两个 host 应当并行');
    limiter.close();
  });

  test('全局并发上限生效', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 4,
      minInterval: Duration.zero,
      globalConcurrency: 4,
    );
    var active = 0;
    var peak = 0;
    final tasks = List.generate(12, (i) {
      return limiter.run('host$i.com', () async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        active--;
      });
    });
    await Future.wait(tasks);
    expect(peak, lessThanOrEqualTo(4));
    expect(peak, greaterThanOrEqualTo(2));
    limiter.close();
  });

  test('最小间隔把连续请求拉开', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 4,
      minInterval: const Duration(milliseconds: 60),
      globalConcurrency: 8,
    );
    // 用与限流器同一个时钟量：Windows 上 Stopwatch 与 DateTime.now 的
    // 取整时机不同，拿 Stopwatch 量 DateTime 排出来的节奏会偶发差十几毫秒。
    final starts = <int>[];
    final begin = DateTime.now();
    await Future.wait(
      List.generate(4, (_) {
        return limiter.run('a.com', () async {
          starts.add(DateTime.now().difference(begin).inMicroseconds);
        });
      }),
    );
    starts.sort();
    expect(starts.length, 4);
    for (var i = 1; i < starts.length; i++) {
      final gapUs = starts[i] - starts[i - 1];
      expect(
        gapUs,
        greaterThanOrEqualTo(45_000),
        reason: '相邻请求的发起间隔应接近 60ms，实际 ${gapUs / 1000}ms',
      );
    }
    limiter.close();
  });

  test('连续失败达到阈值后暂停该 host', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 1,
      minInterval: Duration.zero,
      failureThreshold: 3,
      failurePause: const Duration(milliseconds: 120),
    );
    for (var i = 0; i < 3; i++) {
      await expectLater(
        limiter.run('bad.com', () async => throw StateError('boom')),
        throwsStateError,
      );
    }
    expect(limiter.isPaused('bad.com'), isTrue);

    final sw = Stopwatch()..start();
    await limiter.run('bad.com', () async {});
    sw.stop();
    expect(
      sw.elapsedMilliseconds,
      greaterThanOrEqualTo(80),
      reason: '暂停期内应等待退避时间',
    );
    expect(limiter.isPaused('bad.com'), isFalse);
    limiter.close();
  });

  test('成功会清零失败计数', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 1,
      minInterval: Duration.zero,
      failureThreshold: 2,
    );
    await expectLater(
      limiter.run('h.com', () async => throw StateError('x')),
      throwsStateError,
    );
    await limiter.run('h.com', () async {});
    await expectLater(
      limiter.run('h.com', () async => throw StateError('x')),
      throwsStateError,
    );
    expect(limiter.isPaused('h.com'), isFalse);
    limiter.close();
  });

  test('close 后拒绝新任务', () async {
    final limiter = RateLimiter();
    limiter.close();
    await expectLater(
      limiter.run('a.com', () async {}),
      throwsA(isA<StateError>()),
    );
  });

  test('host 归一化：大小写与端口不影响配额', () async {
    final limiter = RateLimiter(
      perHostConcurrency: 1,
      minInterval: Duration.zero,
    );
    var active = 0;
    var peak = 0;
    await Future.wait([
      limiter.run('A.com:8080', () async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        active--;
      }),
      limiter.run('a.com', () async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        active--;
      }),
    ]);
    expect(peak, 1);
    limiter.close();
  });
}
