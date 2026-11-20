/// 按 host 的并发限制与限速。
///
/// 为什么需要它：抓章节目录时同时开 50 个请求，目标站点要么直接 429，
/// 要么把整个出口 IP 拉黑；而串行抓 200 章又要几分钟。实践下来
/// 「同一 host 3 并发 + 最小间隔 100ms」是「不被封」和「不太慢」之间的平衡点。
///
/// 三层约束：
/// 1. 每 host 并发上限（默认 3）
/// 2. 每 host 最小发起间隔（默认 100ms）
/// 3. 全局并发上限（默认 16，防止 20 个书源同时抓把本机端口耗尽）
///
/// 外加一条保护：同一 host 连续失败 3 次就暂停 5 秒。被墙/被封的站点
/// 重试只会让情况更糟，退避比硬冲有效。
library;

import 'dart:async';
import 'dart:collection';

/// 限流器。
///
/// 实例应由调用方持有并复用；[RateLimiter.run] 是可重入的（同一 host 的
/// 任务排队而不是互斥锁式的死等）。
class RateLimiter {
  RateLimiter({
    this.perHostConcurrency = 3,
    this.minInterval = const Duration(milliseconds: 100),
    this.globalConcurrency = 16,
    this.failureThreshold = 3,
    this.failurePause = const Duration(seconds: 5),
    DateTime Function()? clock,
  })  : assert(perHostConcurrency > 0),
        assert(globalConcurrency > 0),
        _clock = clock ?? DateTime.now;

  /// 单个 host 的最大并发。
  final int perHostConcurrency;

  /// 单个 host 两次请求开始之间的最小间隔。
  final Duration minInterval;

  /// 全局最大并发。
  final int globalConcurrency;

  /// 连续失败多少次后暂停该 host。
  final int failureThreshold;

  /// 暂停时长。
  final Duration failurePause;

  final DateTime Function() _clock;

  final Map<String, _HostState> _hosts = {};

  int _globalActive = 0;
  final Queue<Completer<void>> _globalWaiters = Queue<Completer<void>>();

  bool _closed = false;

  /// 当前全局活跃任务数。
  int get activeTotal => _globalActive;

  /// 某 host 当前活跃任务数。
  int activeFor(String host) => _hosts[_normalize(host)]?.active ?? 0;

  /// 某 host 是否处于失败退避中。
  bool isPaused(String host) {
    final st = _hosts[_normalize(host)];
    final until = st?.pausedUntil;
    return until != null && _clock().isBefore(until);
  }

  /// 在某 host 的配额下执行 [task]。
  ///
  /// 任务抛出的异常会原样向上传递，同时参与「连续失败」统计。
  Future<T> run<T>(String host, Future<T> Function() task) async {
    if (_closed) {
      throw StateError('RateLimiter 已关闭');
    }
    final key = _normalize(host);
    final st = _hosts.putIfAbsent(key, _HostState.new);

    await _acquireHost(st);
    try {
      await _acquireGlobal();
      try {
        final result = await task();
        st.consecutiveFailures = 0;
        st.pausedUntil = null;
        return result;
      } catch (_) {
        _noteFailure(st);
        rethrow;
      } finally {
        _releaseGlobal();
      }
    } finally {
      _releaseHost(st);
    }
  }

  /// 关闭限流器：排队中的任务立即失败，不再接受新任务。
  ///
  /// 正在执行的任务不受影响（不强杀网络请求，那会在上层留下写到一半的文件）。
  void close() {
    _closed = true;
    for (final w in _globalWaiters) {
      if (!w.isCompleted) {
        w.completeError(StateError('RateLimiter 已关闭'));
      }
    }
    _globalWaiters.clear();
    for (final st in _hosts.values) {
      for (final w in st.waiters) {
        if (!w.isCompleted) {
          w.completeError(StateError('RateLimiter 已关闭'));
        }
      }
      st.waiters.clear();
    }
    _hosts.clear();
  }

  /// 清空某 host 的退避状态（例如用户手动重试）。
  void resetHost(String host) {
    final st = _hosts[_normalize(host)];
    if (st == null) return;
    st.consecutiveFailures = 0;
    st.pausedUntil = null;
  }

  // ---------------------------------------------------------------------------

  void _noteFailure(_HostState st) {
    st.consecutiveFailures++;
    if (failureThreshold > 0 && st.consecutiveFailures >= failureThreshold) {
      st.pausedUntil = _clock().add(failurePause);
      st.consecutiveFailures = 0;
    }
  }

  /// 取一个 host 槽位。
  ///
  /// 槽位采用「直接转交」语义：释放时有排队者就把配额转给它，而不是先减后加。
  /// 如果先减后加，被唤醒的协程会发现队列非空又去排队，最终没人再唤醒它，
  /// 整个 host 会永久卡死（并发限流最常见的死锁写法）。
  Future<void> _acquireHost(_HostState st) async {
    if (st.active < perHostConcurrency && st.waiters.isEmpty) {
      st.active++;
    } else {
      final w = Completer<void>();
      st.waiters.add(w);
      await w.future;
    }
    await _waitPacing(st);
  }

  /// 拿到槽位之后再等节奏（退避 / 最小间隔）。
  ///
  /// 刻意在槽位内等待：这样 3 个并发任务仍然只会以 1/100ms 的速率发起，
  /// 而不是「3 个一起冲出去」——后者对防封毫无意义。
  Future<void> _waitPacing(_HostState st) async {
    while (true) {
      final now = _clock();
      final paused = st.pausedUntil;
      if (paused != null && now.isBefore(paused)) {
        await Future<void>.delayed(paused.difference(now));
        continue;
      }
      final last = st.lastStart;
      if (last != null && minInterval > Duration.zero) {
        final earliest = last.add(minInterval);
        if (now.isBefore(earliest)) {
          await Future<void>.delayed(earliest.difference(now));
          continue;
        }
      }
      st.lastStart = now;
      return;
    }
  }

  void _releaseHost(_HostState st) {
    if (st.waiters.isNotEmpty) {
      final w = st.waiters.removeFirst();
      if (!w.isCompleted) w.complete();
      return;
    }
    st.active--;
  }

  Future<void> _acquireGlobal() async {
    if (_globalActive < globalConcurrency && _globalWaiters.isEmpty) {
      _globalActive++;
      return;
    }
    final w = Completer<void>();
    _globalWaiters.add(w);
    await w.future;
  }

  void _releaseGlobal() {
    if (_globalWaiters.isNotEmpty) {
      final w = _globalWaiters.removeFirst();
      if (!w.isCompleted) w.complete();
      return;
    }
    _globalActive--;
  }

  /// host 归一化：大小写、末尾点、端口都不影响配额划分。
  static String _normalize(String host) {
    var h = host.trim().toLowerCase();
    if (h.isEmpty) return 'unknown';
    final colon = h.lastIndexOf(':');
    if (colon > 0 && !h.contains(']')) {
      final port = h.substring(colon + 1);
      if (int.tryParse(port) != null) h = h.substring(0, colon);
    }
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    return h.isEmpty ? 'unknown' : h;
  }
}

class _HostState {
  int active = 0;
  final Queue<Completer<void>> waiters = Queue<Completer<void>>();
  DateTime? lastStart;
  DateTime? pausedUntil;
  int consecutiveFailures = 0;
}
