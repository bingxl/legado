import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `bookmarks` 表访问。
class BookmarkDao {
  BookmarkDao(this._db);

  final Database _db;

  static const String _table = Bookmark.tableBookmarks;

  static const List<String> _columns = [
    'time',
    'bookName',
    'bookAuthor',
    'chapterIndex',
    'chapterPos',
    'chapterName',
    'bookText',
    'content',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(Bookmark bookmark) {
    final row = bookmark.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<Bookmark> get all => _db
      .select(
        'select * from `$_table` order by bookName collate localized, '
        'bookAuthor collate localized, chapterIndex, chapterPos',
      )
      .map((r) => Bookmark.fromRow(r))
      .toList();

  List<Bookmark> getByBook(String bookName, String bookAuthor) => _db
      .select(
        'select * from `$_table` where bookName = ? and bookAuthor = ? '
        'order by chapterIndex',
        [bookName, bookAuthor],
      )
      .map((r) => Bookmark.fromRow(r))
      .toList();

  /// 注意 Kotlin 原 SQL 的 `and ... or ...` 没有括号，这里保持同样语义
  /// （`or` 会绕过书名条件），不要「顺手修正」否则行为与原版不一致。
  List<Bookmark> search(String bookName, String bookAuthor, String key) => _db
      .select(
        'SELECT * FROM `$_table` where bookName = ? and bookAuthor = ? '
        "and chapterName like '%'||?||'%' or content like '%'||?||'%' "
        'order by chapterIndex',
        [bookName, bookAuthor, key, key],
      )
      .map((r) => Bookmark.fromRow(r))
      .toList();

  void insert(Bookmark bookmark) => _db.execute(_insertSql, _params(bookmark));

  void update(Bookmark bookmark) {
    final row = bookmark.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `time` = ?',
      [for (final column in _columns.skip(1)) row[column], bookmark.time],
    );
  }

  void delete(Bookmark bookmark) =>
      _db.execute('delete from `$_table` where `time` = ?', [bookmark.time]);
}
