/// 缓存任务的四种状态，与 Go 内核字符串取值一致（UI 按字符串判断）。
abstract final class CacheState {
  static const String running = 'running';
  static const String done = 'done';
  static const String canceled = 'canceled';
  static const String failed = 'failed';
}

/// 缓存范围（契约里是小写字符串，不是枚举）。
abstract final class CacheScope {
  static const String all = 'all';
  static const String remaining = 'remaining';
  static const String missing = 'missing';
  static const String chapters = 'chapters';

  static const List<String> values = [all, remaining, missing, chapters];
}

/// 一次缓存任务的快照。
class CacheJob {
  CacheJob({
    required this.bookId,
    required this.bookName,
    required this.scope,
    required this.total,
    this.state = CacheState.running,
    this.done = 0,
    this.failed = 0,
    this.message = '',
    required this.startedAt,
    this.finishedAt,
  });

  final int bookId;
  final String bookName;
  final String scope;

  /// 可变字段：后台任务原地更新，调用方拿到的 Map 是快照。
  String state;
  final int total;
  int done;
  int failed;
  String message;
  final int startedAt;
  int? finishedAt;

  bool get isRunning => state == CacheState.running;

  Map<String, Object?> toJson() => <String, Object?>{
        'bookId': bookId,
        'bookName': bookName,
        'scope': scope,
        'state': state,
        'total': total,
        'done': done,
        'failed': failed,
        'message': message,
        'startedAt': _stamp(startedAt),
        if (finishedAt != null) 'finishedAt': _stamp(finishedAt!),
      };

  static String _stamp(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
          .toIso8601String();
}
