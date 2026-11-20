/// 阅读进度（Flutter 版新增表）。
///
/// **为什么需要它**：Kotlin 版把进度存在 `books` 的 `durChapter*` 四列里，
/// 只有「章内字符偏移」，没有「章内百分比」。而 UI 契约
/// （`Shelf.SaveProgress` / `GetProgress`）传的是 `scrollPercent` ——
/// 翻页模式下恢复位置靠它，书架上的「已读 xx%」也靠它。
///
/// 折中做法，与 `app_settings` 那张表同理：
///   * `books.durChapter*` 照旧写（Kotlin 兼容、`Book` 实体不用改），
///   * 多存一张 `reading_progress` 存百分比与写入时间。
///
/// 不用 `books` 加列：那会让 `Book.toRow/fromRow` 与 22 张表的
/// 「与 Room 一致」这条约束全部失效，代价远大于一张附属表。
class ReadingProgress {
  const ReadingProgress({
    required this.bookUrl,
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.chapterPos = 0,
    this.scrollPercent = 0,
    this.updatedAt = 0,
  });

  static const String tableReadingProgress = 'reading_progress';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `reading_progress` (
  `bookUrl` TEXT NOT NULL,
  `chapterIndex` INTEGER NOT NULL DEFAULT 0,
  `chapterTitle` TEXT NOT NULL DEFAULT '',
  `chapterPos` INTEGER NOT NULL DEFAULT 0,
  `scrollPercent` REAL NOT NULL DEFAULT 0,
  `updatedAt` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`bookUrl`)
)''';

  final String bookUrl;
  final int chapterIndex;
  final String chapterTitle;
  final int chapterPos;

  /// 章内百分比，口径 **0~100**（与 UI 的 `reader_controller` 一致）。
  final double scrollPercent;

  /// Unix 毫秒。
  final int updatedAt;

  factory ReadingProgress.fromRow(Map<String, Object?> row) => ReadingProgress(
        bookUrl: (row['bookUrl'] as String?) ?? '',
        chapterIndex: (row['chapterIndex'] as int?) ?? 0,
        chapterTitle: (row['chapterTitle'] as String?) ?? '',
        chapterPos: (row['chapterPos'] as int?) ?? 0,
        scrollPercent: (row['scrollPercent'] as num?)?.toDouble() ?? 0,
        updatedAt: (row['updatedAt'] as int?) ?? 0,
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'bookUrl': bookUrl,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'chapterPos': chapterPos,
        'scrollPercent': scrollPercent,
        'updatedAt': updatedAt,
      };
}
