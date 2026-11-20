import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `bookmark` 表访问（契约书签，非 Kotlin 的 `bookmarks`）。
class BookmarkItemDao {
  BookmarkItemDao(this._db);

  final Database _db;

  static const String _table = BookmarkItem.table;

  static const String _insertSql =
      'INSERT INTO `$_table` (`book_id`, `chapter_index`, `chapter_title`, '
      '`chapter_pos`, `content`, `note`, `created_at`) VALUES (?, ?, ?, ?, ?, ?, ?)';

  /// 新增并返回自增 id。
  int insert(BookmarkItem item) {
    _db.execute(_insertSql, [
      item.bookId,
      item.chapterIndex,
      item.chapterTitle,
      item.chapterPos,
      item.content,
      item.note,
      item.createdAt,
    ]);
    return _db.lastInsertRowId;
  }

  BookmarkItem? get(int id) {
    final rows = _db.select('select * from `$_table` where `id` = ?', [id]);
    return rows.isEmpty ? null : BookmarkItem.fromRow(rows.first);
  }

  /// [bookId] 为 0 表示全部；按创建时间倒序，id 兜底保证同一秒内稳定。
  List<BookmarkItem> list(int bookId, int limit) {
    final rows = bookId > 0
        ? _db.select(
            'select * from `$_table` where `book_id` = ? '
            'order by `created_at` desc, `id` desc limit ?',
            [bookId, limit],
          )
        : _db.select(
            'select * from `$_table` '
            'order by `created_at` desc, `id` desc limit ?',
            [limit],
          );
    return [for (final row in rows) BookmarkItem.fromRow(row)];
  }

  bool _exists(int id) =>
      _db.select('select 1 from `$_table` where `id` = ? limit 1', [id]).isNotEmpty;

  /// 删一条，返回是否真的删到了（前端据此提示「已被其他窗口删除」）。
  bool remove(int id) {
    if (!_exists(id)) return false;
    _db.execute('delete from `$_table` where `id` = ?', [id]);
    return true;
  }

  /// 只改备注，避免误改正文与位置。
  bool updateNote(int id, String note) {
    if (!_exists(id)) return false;
    _db.execute(
      'update `$_table` set `note` = ? where `id` = ?',
      [note, id],
    );
    return true;
  }

  int count(int bookId) {
    final rows = bookId > 0
        ? _db.select(
            'select count(*) as c from `$_table` where `book_id` = ?', [bookId])
        : _db.select('select count(*) as c from `$_table`');
    return (rows.first['c'] as num?)?.toInt() ?? 0;
  }
}
