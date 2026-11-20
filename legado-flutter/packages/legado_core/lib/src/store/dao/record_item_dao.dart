import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `read_record` 表访问（换章流水，非 Kotlin 的 `readRecord` 时长表）。
class RecordItemDao {
  RecordItemDao(this._db);

  final Database _db;

  static const String _table = RecordItem.table;

  static const String _insertSql =
      'INSERT INTO `$_table` (`book_id`, `book_name`, `chapter_index`, '
      '`chapter_title`, `read_at`) VALUES (?, ?, ?, ?, ?)';

  /// 追加一条流水。
  ///
  /// 去重规则：同书、同**本地日**、同章只留一条；重复打开同一章刷新
  /// `read_at`（历史页的「最近阅读」应当是最新时间）。
  ///
  /// 先 SELECT 再 INSERT/UPDATE 必须在事务里：否则并发换章会插出两条。
  /// 判定用 `read_at >= startOfToday`（本地 0 点）而不是 SQL `date(...,'localtime')`：
  /// SQLite 的 localtime 依赖进程 TZ 环境变量，Windows 上常常没设。
  RecordItem append(
    int bookId,
    String bookName,
    int chapterIndex,
    String chapterTitle, {
    DateTime? now,
  }) {
    final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final today = startOfTodaySeconds(now);
    late final int id;

    runInTransaction(_db, () {
      final existing = _db.select(
        'select `id` from `$_table` where `book_id` = ? and `chapter_index` = ? '
        'and `read_at` >= ? order by `read_at` desc, `id` desc limit 1',
        [bookId, chapterIndex, today],
      );
      if (existing.isEmpty) {
        _db.execute(_insertSql, [bookId, bookName, chapterIndex, chapterTitle, nowSec]);
        id = _db.lastInsertRowId;
        return;
      }
      id = (existing.first['id'] as num).toInt();
      _db.execute(
        'update `$_table` set `book_name` = ?, `chapter_title` = ?, `read_at` = ? '
        'where `id` = ?',
        [bookName, chapterTitle, nowSec, id],
      );
    });

    return get(id)!;
  }

  RecordItem? get(int id) {
    final rows = _db.select('select * from `$_table` where `id` = ?', [id]);
    return rows.isEmpty ? null : RecordItem.fromRow(rows.first);
  }

  /// 按时间倒序分页；[offset] 在 [limit] 前（契约参数顺序）。
  List<RecordItem> list(int offset, int limit) {
    final rows = _db.select(
      'select * from `$_table` order by `read_at` desc, `id` desc limit ? offset ?',
      [limit, offset],
    );
    return [for (final row in rows) RecordItem.fromRow(row)];
  }

  /// [beforeDays] ≤ 0 清空；否则删除 N×24 小时以前的记录。
  int clear(int beforeDays, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000 -
        beforeDays * 86400;
    final count = (beforeDays <= 0
            ? _db.select('select count(*) as c from `$_table`')
            : _db.select(
                'select count(*) as c from `$_table` where `read_at` < ?', [cutoff]))
        .first['c'] as num;
    if (count == 0) return 0;
    if (beforeDays <= 0) {
      _db.execute('delete from `$_table`');
    } else {
      _db.execute('delete from `$_table` where `read_at` < ?', [cutoff]);
    }
    return count.toInt();
  }

  /// 阅读统计。天数按本地日历日切分，在 Dart 侧做以免依赖 SQLite TZ。
  RecordStats stats() {
    final rows = _db.select('select `book_id`, `read_at` from `$_table`');
    final days = <String>{};
    final books = <int>{};
    for (final row in rows) {
      final seconds = (row['read_at'] as num?)?.toInt() ?? 0;
      if (seconds > 0) {
        final local = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
        days.add('${local.year}-${local.month}-${local.day}');
      }
      books.add((row['book_id'] as num?)?.toInt() ?? 0);
    }
    return RecordStats(days: days.length, books: books.length, records: rows.length);
  }
}
