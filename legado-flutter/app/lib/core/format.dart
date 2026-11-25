// 跨模块共用的时间格式化片段。
// tools / rss / source 各写一份补零函数，格式稍有偏差就会出现「1 月 3 日」与
// 「01-03」混排，这里收成同一套。

String twoDigits(int value) => value.toString().padLeft(2, '0');

String formatClock(DateTime time) =>
    '${twoDigits(time.hour)}:${twoDigits(time.minute)}';

/// 精确到分钟：`yyyy-MM-dd HH:mm`。
String formatDateTime(DateTime time) =>
    '${time.year}-${twoDigits(time.month)}-${twoDigits(time.day)} '
    '${twoDigits(time.hour)}:${twoDigits(time.minute)}';
