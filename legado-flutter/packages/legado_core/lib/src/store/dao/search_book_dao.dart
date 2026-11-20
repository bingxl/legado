import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `searchBooks` 表访问。
class SearchBookDao {
  SearchBookDao(this._db);

  final Database _db;

  static const String _table = SearchBook.tableSearchBooks;

  static const List<String> _columns = [
    'bookUrl',
    'origin',
    'originName',
    'type',
    'name',
    'author',
    'kind',
    'coverUrl',
    'intro',
    'wordCount',
    'latestChapterTitle',
    'tocUrl',
    'time',
    'variable',
    'originOrder',
    'chapterWordCountText',
    'chapterWordCount',
    'respondTime',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(SearchBook book) {
    final row = book.toRow();
    return [for (final column in _columns) row[column]];
  }

  SearchBook? get(String bookUrl) {
    final rows = _db.select('select * from `$_table` where bookUrl = ?', [bookUrl]);
    return rows.isEmpty ? null : SearchBook.fromRow(rows.first);
  }

  /// 同类书里书源排序最高的一条（只考虑仍存在的书源）。
  SearchBook? getFirstByNameAuthor(String name, String author) {
    final rows = _db.select(
      'select * from `$_table` where name = ? and author = ? '
      'and origin in (select bookSourceUrl from book_sources) '
      'order by originOrder limit 1',
      [name, author],
    );
    return rows.isEmpty ? null : SearchBook.fromRow(rows.first);
  }

  /// 换源列表：同名作者、书源启用、按书源顺序。
  List<SearchBook> changeSourceByGroup(String name, String author, String sourceGroup) => _db
      .select(
        'select t1.*, t2.customOrder as originOrder from `$_table` as t1 '
        'inner join book_sources as t2 on t1.origin = t2.bookSourceUrl '
        "where t1.name = ? and t1.author like '%'||?||'%' "
        "and t2.enabled = 1 and t2.bookSourceGroup like '%'||?||'%' "
        'order by t2.customOrder',
        [name, author, sourceGroup],
      )
      .map((r) => SearchBook.fromRow(r))
      .toList();

  List<SearchBook> getEnableHasCover(String name, String author) => _db
      .select(
        'select t1.*, t2.customOrder as originOrder from `$_table` as t1 '
        'inner join book_sources as t2 on t1.origin = t2.bookSourceUrl '
        "where t1.name = ? and t1.author = ? and t1.coverUrl is not null "
        "and t1.coverUrl <> '' and t2.enabled = 1 order by t2.customOrder",
        [name, author],
      )
      .map((r) => SearchBook.fromRow(r))
      .toList();

  void insert(SearchBook book) => _db.execute(_insertSql, _params(book));

  void insertAll(List<SearchBook> books) {
    if (books.isEmpty) return;
    final stmt = _db.prepare(_insertSql);
    try {
      for (final book in books) {
        stmt.execute(_params(book));
      }
    } finally {
      stmt.close();
    }
  }

  void update(SearchBook book) {
    final row = book.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `bookUrl` = ?',
      [for (final column in _columns.skip(1)) row[column], book.bookUrl],
    );
  }

  void delete(SearchBook book) =>
      _db.execute('delete from `$_table` where bookUrl = ?', [book.bookUrl]);

  void clear(String name, String author) => _db.execute(
        'delete from `$_table` where name = ? and author = ?',
        [name, author],
      );

  void clearExpired(int time) =>
      _db.execute('delete from `$_table` where time < ?', [time]);
}
