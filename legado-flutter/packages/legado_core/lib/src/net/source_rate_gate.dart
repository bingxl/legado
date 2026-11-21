/// 按书源 `concurrentRate` 限速（对齐 Kotlin `ConcurrentRateLimiter`）。
///
/// 书源里的写法有两种：
/// - `"1000"`：两次请求之间至少间隔 1000ms（串行，不并发）；
/// - `"3/1000"`：1000ms 窗口内最多 3 次请求；
/// - 空串 / `"0"`：不限制（沿用 [RateLimiter] 的全局策略）。
///
/// 与 Kotlin 的差别：原版超限时抛 `ConcurrentException` 由上层重试，
/// 这里直接 `await` 等到窗口放行。对调用方来说语义一样（不会超发），
/// 但不用每个调用点都写重试循环，也不会把异常冒到 UI。
library;

/// 单个书源的请求闸门。
class SourceRateGate {
  SourceRateGate._(this.maxPerWindow, this.window, this._clock);

  /// 窗口内允许的请求数。
  final int maxPerWindow;

  /// 统计窗口。
  final Duration window;

  final DateTime Function() _clock;

  /// 窗口内已发出的请求开始时间（升序）。
  final List<DateTime> _starts = <DateTime>[];

  /// 解析 `concurrentRate`；不需要限速时返回 null。
  static SourceRateGate? parse(
    String? rate, {
    DateTime Function()? clock,
  }) {
    final text = (rate ?? '').trim();
    if (text.isEmpty || text == '0') return null;
    final now = clock ?? DateTime.now;
    final slash = text.indexOf('/');
    if (slash < 0) {
      // 只给一个数：当作最小间隔（毫秒）。
      final interval = int.tryParse(text);
      if (interval == null || interval <= 0) return null;
      return SourceRateGate._(
        1,
        Duration(milliseconds: interval),
        now,
      );
    }
    final count = int.tryParse(text.substring(0, slash).trim());
    final windowMs = int.tryParse(text.substring(slash + 1).trim());
    if (count == null || count <= 0 || windowMs == null || windowMs <= 0) {
      return null;
    }
    return SourceRateGate._(
      count,
      Duration(milliseconds: windowMs),
      now,
    );
  }

  /// 等到允许发下一个请求，然后登记一次。Dart 单 isolate 下
  /// 「清理 + 判断 + 登记」之间没有 await，天然原子，不需要额外加锁。
  Future<void> acquire() async {
    while (true) {
      final now = _clock();
      _starts.removeWhere((t) => now.difference(t) >= window);
      if (_starts.length < maxPerWindow) {
        _starts.add(now);
        return;
      }
      final wait = window - now.difference(_starts.first);
      await Future<void>.delayed(
        wait > Duration.zero ? wait : const Duration(milliseconds: 1),
      );
    }
  }

  /// 包一次请求。
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    return action();
  }
}

/// 书源 → 闸门的注册表。
///
/// 按书源地址缓存；书源改了 `concurrentRate` 时旧闸门直接丢弃重建，
/// 免得改了配置还要重启进程。
class SourceRateGateRegistry {
  SourceRateGateRegistry({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;
  final Map<String, ({String rate, SourceRateGate? gate})> _gates = {};

  /// 取书源的闸门；不需要限速时返回 null。
  SourceRateGate? gateOf(String sourceKey, String? rate) {
    final text = (rate ?? '').trim();
    final cached = _gates[sourceKey];
    if (cached != null && cached.rate == text) return cached.gate;
    final gate = SourceRateGate.parse(text, clock: _clock);
    _gates[sourceKey] = (rate: text, gate: gate);
    return gate;
  }

  /// 清空缓存（测试与「书源全部重载」时用）。
  void clear() => _gates.clear();
}
