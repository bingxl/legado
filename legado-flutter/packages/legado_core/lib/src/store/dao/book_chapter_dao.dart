import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `chapters` 表访问，SQL 对应 Kotlin `BookChapterDao`。
class BookChapterDao {
  BookChapterDao(this._db);

  final Database _db;

  static const String _table = BookChapter.tableChapters;

  static const List<String> _columns = [
    'url',
    'title',
    'isVolume',
    'baseUrl',
    'bookUrl',
    'index',
    'isVip',
    'isPay',
    'resourceUrl',
    'tag',
    'wordCount',
    'start',
    'end',
    'startFragmentId',
    'endFragmentId',
    'variable',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(BookChapter chapter) {
    final row = chapter.toRow();
    return [for (final column in _columns) row[column]];
  }

  /// 按章节标题模糊搜索（不带范围）。
  List<BookChapter> search(String bookUrl, String key) => _db
      .select(
        'SELECT * FROM `$_table` where bookUrl = ? and title like '
        "'%'||?||'%' order by `index`",
        [bookUrl, key],
      )
      .map((r) => BookChapter.fromRow(r))
      .toList();

  /// 按标题 + 章节序号区间搜索，供「查找上下章」使用。
  List<BookChapter> searchRange(String bookUrl, String key, int start, int end) => _db
      .select(
        'SELECT * FROM `$_table` where bookUrl = ? and `index` >= ? and `index` <= ? '
        "and title like '%'||?||'%' order by `index`",
        [bookUrl, start, end, key],
      )
      .map((r) => BookChapter.fromRow(r))
      .toList();

  List<BookChapter> getChapterList(String bookUrl) => _db
      .select('select * from `$_table` where bookUrl = ? order by `index`', [bookUrl])
      .map((r) => BookChapter.fromRow(r))
      .toList();

  List<BookChapter> getChapterListRange(String bookUrl, int start, int end) => _db
      .select(
        'select * from `$_table` where bookUrl = ? and `index` >= ? and `index` <= ? '
        'order by `index`',
        [bookUrl, start, end],
      )
      .map((r) => BookChapter.fromRow(r))
      .toList();

  BookChapter? getChapter(String bookUrl, int index) {
    final rows = _db.select(
      'select * from `$_table` where bookUrl = ? and `index` = ?',
      [bookUrl, index],
    );
    return rows.isEmpty ? null : BookChapter.fromRow(rows.first);
  }

  BookChapter? getChapterByTitle(String bookUrl, String title) {
    final rows = _db.select(
      'select * from `$_table` where bookUrl = ? and `title` = ?',
      [bookUrl, title],
    );
    return rows.isEmpty ? null : BookChapter.fromRow(rows.first);
  }

  int getChapterCount(String bookUrl) =>
      (_db.select(
                'select count(url) as c from `$_table` where bookUrl = ?',
                [bookUrl],
              ).first['c'] as int?) ??
      0;

  List<String> getUrls(String bookUrl) => _db
      .select('select url from `$_table` where bookUrl = ?', [bookUrl])
      .map((r) => r['url'] as String)
      .toList();

  void insert(BookChapter chapter) => _db.execute(_insertSql, _params(chapter));

  /// 批量插入。
  ///
  /// 必须单事务：几千章逐条提交时，每章一次 fsync，实测能慢到分钟级。
  void insertAll(List<BookChapter> chapters) {
    if (chapters.isEmpty) return;
    runInTransaction(_db, () {
      final stmt = _db.prepare(_insertSql);
      try {
        for (final chapter in chapters) {
          stmt.execute(_params(chapter));
        }
      } finally {
        stmt.close();
      }
    });
  }

  void update(BookChapter chapter) {
    final row = chapter.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `url` = ? and `bookUrl` = ?',
      [
        for (final column in _columns.skip(1)) row[column],
        chapter.url,
        chapter.bookUrl,
      ],
    );
  }

  void updateAll(List<BookChapter> chapters) {
    if (chapters.isEmpty) return;
    runInTransaction(_db, () {
      for (final chapter in chapters) {
        update(chapter);
      }
    });
  }

  void deleteByBookUrl(String bookUrl) =>
      _db.execute('delete from `$_table` where bookUrl = ?', [bookUrl]);

  void upWordCount(String bookUrl, String url, String wordCount) => _db.execute(
        'update `$_table` set wordCount = ? where bookUrl = ? and url = ?',
        [wordCount, bookUrl, url],
      );
}
