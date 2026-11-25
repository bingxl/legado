/// 「我的」/工具页共用的纯函数：体积、时间、按天分组、缓存进度。
///
/// 为什么单独抽成文件：
/// 1. 三个工具页都要用，塞在任一 widget 里都会被别的页面反向 import；
/// 2. 这些逻辑必须能脱离 Flutter 单测（`test/tools/tools_format_test.dart`）；
/// 3. pubspec 只有 http + cupertino_icons，不能引 `intl`，日期只能手拼。
library;

import '../../core/format.dart';

/// 体积格式化：B 取整，KB/MB/GB 保留一位小数。
///
/// 只做到 GB 是刻意的：缓存体积几乎不可能到 TB，多一档反而让
/// 「1536.0 MB」这种不该出现的输出有了藏身处。
String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

/// 解析 core 的时间字段。core 统一输出 RFC3339（带时区），
/// 解析失败返回 null 而不是抛异常——一条脏数据不该让整页崩掉。
///
/// 兼容 unix 秒（旧库 / 测试夹具会给数字）。
DateTime? parseTime(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toLocal();
  if (raw is num) {
    if (raw <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
  }
  final text = '$raw'.trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed?.toLocal();
}

/// 日期分组标题：今天 / 昨天 / yyyy-MM-dd。
///
/// [now] 只为单测注入固定时间，生产调用不用传。
String dayLabel(DateTime day, {DateTime? now}) {
  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final diff = today.difference(_dateOnly(day)).inDays;
  if (diff == 0) return '今天';
  if (diff == 1) return '昨天';
  return '${day.year}-${_two(day.month)}-${_two(day.day)}';
}

/// 24 小时制的时分（阅读记录列表用）。
String formatClock(DateTime time) => '${_two(time.hour)}:${_two(time.minute)}';

/// 完整日期时间，用于需要精确到分钟的场景（如章节缓存时间提示）。
String formatDateTime(DateTime time) =>
    '${time.year}-${_two(time.month)}-${_two(time.day)} '
    '${_two(time.hour)}:${_two(time.minute)}';

/// 取不到时间时的兜底分组名。
const String unknownDayLabel = '未知时间';

/// 一个日期分组。列表由分组标题 + 若干条目组成，扁平渲染比
/// 嵌套 ListView 更容易和分隔线、下拉刷新配合。
class DayGroup<T> {
  const DayGroup({required this.label, required this.items});

  final String label;
  final List<T> items;
}

/// 按 [timeOf] 的日期分组，保持入参顺序（core 已按时间倒序返回）。
///
/// 时间缺失的条目归到「未知时间」，放在最后；不能丢掉它们——
/// 用户看到的书签数量应该和「我的」页的统计一致。
List<DayGroup<T>> groupByDay<T>(
  List<T> items,
  DateTime? Function(T item) timeOf, {
  DateTime? now,
}) {
  final buckets = <String, List<T>>{};
  final order = <String>[];
  for (final item in items) {
    final time = timeOf(item);
    final label = time == null ? unknownDayLabel : dayLabel(time, now: now);
    final bucket = buckets[label];
    if (bucket == null) {
      buckets[label] = <T>[item];
      order.add(label);
    } else {
      bucket.add(item);
    }
  }
  // 「未知时间」永远垫底，避免夹在今天和昨天之间。
  order.sort((a, b) {
    if (a == unknownDayLabel) return 1;
    if (b == unknownDayLabel) return -1;
    return 0;
  });
  return [
    for (final label in order)
      DayGroup<T>(label: label, items: buckets[label]!),
  ];
}

/// 缓存任务进度（0~1）。done+failed 才是「处理过的章节数」，
/// total 为 0（目录还没解析出来）时按 0 处理，否则会出现除零的 NaN。
double cacheProgress(int done, int failed, int total) {
  if (total <= 0) return 0;
  final value = (done + failed) / total;
  return value.clamp(0.0, 1.0);
}

/// 进度文案，与进度条一起显示，避免用户只看到一个 3% 的条。
String cacheProgressLabel(int done, int failed, int total) {
  final safeTotal = total < 0 ? 0 : total;
  final handled = done + failed;
  return '$handled/$safeTotal';
}

DateTime _dateOnly(DateTime t) => DateTime(t.year, t.month, t.day);

String _two(int value) => twoDigits(value);
