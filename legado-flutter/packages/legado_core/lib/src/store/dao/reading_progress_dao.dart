import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `reading_progress` 表访问（Flutter 版新增，见 [ReadingProgress] 的说明）。
///
/// 只做读写，不做「哪个更权威」的判断：`books.durChapter*` 与这里由
/// `ShelfService.SaveProgress` 在同一个事务里一起写，读的时候优先用本表
/// （它有百分比），缺失时回落到 `books`。
class ReadingProgressDao {
  ReadingProgressDao(this._db);

  final Database _db;

  static const String _table = ReadingProgress.tableReadingProgress;

  static const String _upsertSql =
      'INSERT OR REPLACE INTO `$_table` '
      '(`bookUrl`, `chapterIndex`, `chapterTitle`, `chapterPos`, `scrollPercent`, `updatedAt`) '
      'VALUES (?, ?, ?, ?, ?, ?)';

  ReadingProgress? get(String bookUrl) {
    final rows = _db.select('SELECT * FROM `$_table` WHERE `bookUrl` = ?', [bookUrl]);
    return rows.isEmpty ? null : ReadingProgress.fromRow(rows.first);
  }

  void put(ReadingProgress progress) => _db.execute(_upsertSql, [
        progress.bookUrl,
        progress.chapterIndex,
        progress.chapterTitle,
        progress.chapterPos,
        progress.scrollPercent,
        progress.updatedAt,
      ]);

  void delete(String bookUrl) =>
      _db.execute('DELETE FROM `$_table` WHERE `bookUrl` = ?', [bookUrl]);

  int get count =>
      (_db.select('SELECT COUNT(*) AS c FROM `$_table`').first['c'] as int?) ?? 0;
}
