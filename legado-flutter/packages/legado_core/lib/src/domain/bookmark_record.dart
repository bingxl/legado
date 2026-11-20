/// 书签与阅读记录（Flutter 内核契约表）。
///
/// **为什么不是 Kotlin 的 `bookmarks` / `readRecord`**：
/// 那两张表的键是 `(time)` / `(deviceId, bookName)`，没有 `bookId`、
/// `note`、`chapterTitle` 这些 UI 契约字段，而且把「阅读时长统计」和
/// 「换章流水」混在一张表里。旧 Go 内核的做法是另建两张幂等表，
/// 与 Room 表并存、互不干扰；这里沿用同一策略。
///
/// 时间列一律 `INTEGER` Unix **秒**，序列化时转 RFC3339 字符串给 UI
/// （`app/lib/features/tools/tools_format.dart` 的 `parseTime` 同时兼容秒数字）。
library;

import 'row_utils.dart';

/// 一条书签，对应契约 `BookmarkItem`。
class BookmarkItem {
  BookmarkItem({
    this.id = 0,
    required this.bookId,
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.chapterPos = 0,
    this.content = '',
    this.note = '',
    this.createdAt = 0,
  });

  static const String table = 'bookmark';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `bookmark` (
  `id` INTEGER PRIMARY KEY AUTOINCREMENT,
  `book_id` INTEGER NOT NULL,
  `chapter_index` INTEGER NOT NULL DEFAULT 0,
  `chapter_title` TEXT NOT NULL DEFAULT '',
  `chapter_pos` INTEGER NOT NULL DEFAULT 0,
  `content` TEXT NOT NULL DEFAULT '',
  `note` TEXT NOT NULL DEFAULT '',
  `created_at` INTEGER NOT NULL DEFAULT 0
)''';

  static const String createIndexSql =
      'CREATE INDEX IF NOT EXISTS `idx_bookmark_book` '
      'ON `bookmark` (`book_id`, `chapter_index`)';

  /// SQLite rowid，新增前为 0。
  int id;
  int bookId;
  int chapterIndex;
  String chapterTitle;
  int chapterPos;
  String content;
  String note;

  /// Unix 秒。
  int createdAt;

  factory BookmarkItem.fromRow(Map<String, Object?> row) => BookmarkItem(
        id: asInt(row['id']),
        bookId: asInt(row['book_id']),
        chapterIndex: asInt(row['chapter_index']),
        chapterTitle: asString(row['chapter_title']),
        chapterPos: asInt(row['chapter_pos']),
        content: asString(row['content']),
        note: asString(row['note']),
        createdAt: asInt(row['created_at']),
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'book_id': bookId,
        'chapter_index': chapterIndex,
        'chapter_title': chapterTitle,
        'chapter_pos': chapterPos,
        'content': content,
        'note': note,
        'created_at': createdAt,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'chapterPos': chapterPos,
        'content': content,
        'note': note,
        'createdAt': isoSeconds(createdAt),
      };
}

/// 一条换章流水，对应契约 `RecordItem`。
class RecordItem {
  RecordItem({
    this.id = 0,
    required this.bookId,
    this.bookName = '',
    this.chapterIndex = 0,
    this.chapterTitle = '',
    this.readAt = 0,
  });

  static const String table = 'read_record';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `read_record` (
  `id` INTEGER PRIMARY KEY AUTOINCREMENT,
  `book_id` INTEGER NOT NULL,
  `book_name` TEXT NOT NULL DEFAULT '',
  `chapter_index` INTEGER NOT NULL DEFAULT 0,
  `chapter_title` TEXT NOT NULL DEFAULT '',
  `read_at` INTEGER NOT NULL DEFAULT 0
)''';

  static const String createTimeIndexSql =
      'CREATE INDEX IF NOT EXISTS `idx_read_record_time` '
      'ON `read_record` (`read_at` DESC)';

  /// Append 的同书同日同章查重每次换章都会跑；只按时间索引会退化成全表扫。
  static const String createBookIndexSql =
      'CREATE INDEX IF NOT EXISTS `idx_read_record_book` '
      'ON `read_record` (`book_id`, `chapter_index`, `read_at`)';

  int id;
  int bookId;
  String bookName;
  int chapterIndex;
  String chapterTitle;

  /// Unix 秒。
  int readAt;

  factory RecordItem.fromRow(Map<String, Object?> row) => RecordItem(
        id: asInt(row['id']),
        bookId: asInt(row['book_id']),
        bookName: asString(row['book_name']),
        chapterIndex: asInt(row['chapter_index']),
        chapterTitle: asString(row['chapter_title']),
        readAt: asInt(row['read_at']),
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'id': id,
        'book_id': bookId,
        'book_name': bookName,
        'chapter_index': chapterIndex,
        'chapter_title': chapterTitle,
        'read_at': readAt,
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'bookId': bookId,
        'bookName': bookName,
        'chapterIndex': chapterIndex,
        'chapterTitle': chapterTitle,
        'readAt': isoSeconds(readAt),
      };
}

/// 阅读统计，对应契约 `RecordStats`。
///
/// [days] 是**有阅读行为的天数**（本地时区按日切分），不是首末时间差：
/// 断断续续读了 10 天和连续读 10 天都算 10 天。
class RecordStats {
  const RecordStats({required this.days, required this.books, required this.records});

  final int days;
  final int books;
  final int records;

  Map<String, Object?> toJson() => <String, Object?>{
        'days': days,
        'books': books,
        'records': records,
      };
}

/// Unix 秒 → RFC3339（UTC，`Z` 结尾）。
///
/// 不写 `DateTime.now().toItoIso8601String()`：库里的时间是 UTC 秒，
/// 回显时必须用同一个基准，否则「新增返回的 createdAt」和「List 里的」
/// 会在东八区差 8 小时。
String isoSeconds(int seconds) {
  if (seconds <= 0) return '';
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
      .toIso8601String();
}

/// 今天 0 点（本地时区）对应的 Unix 秒。
///
/// 「同书同日同章」里的「日」由用户感知决定，用 UTC 会把东八区
/// 凌晨 0~8 点的阅读算到前一天。
int startOfTodaySeconds([DateTime? now]) {
  final local = (now ?? DateTime.now()).toLocal();
  return DateTime(local.year, local.month, local.day).millisecondsSinceEpoch ~/ 1000;
}
