import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `books` 表访问，SQL 对应 Kotlin `BookDao`。
///
/// 只保留数据层职责：不判断「是否在书架」（`isNotShelf` 是业务规则，归 service）。
class BookDao {
  BookDao(this._db);

  final Database _db;

  static const String _table = Book.tableBooks;

  static const List<String> _columns = [
    'bookUrl',
    'tocUrl',
    'origin',
    'originName',
    'name',
    'author',
    'kind',
    'customTag',
    'coverUrl',
    'customCoverUrl',
    'intro',
    'customIntro',
    'charset',
    'type',
    'group',
    'latestChapterTitle',
    'latestChapterTime',
    'lastCheckTime',
    'lastCheckCount',
    'totalChapterNum',
    'durChapterTitle',
    'durChapterIndex',
    'durChapterPos',
    'durChapterTime',
    'wordCount',
    'canUpdate',
    'order',
    'originOrder',
    'variable',
    'readConfig',
    'syncTime',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  static final String _updateSql = 'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `bookUrl` = ?';

  List<Object?> _params(Book book) {
    final row = book.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<Book> get all =>
      _db.select('SELECT * FROM `$_table`').map((r) => Book.fromRow(r)).toList();

  List<String> get allBookUrls =>
      _db.select('SELECT bookUrl FROM `$_table`').map((r) => r['bookUrl'] as String).toList();

  int get allBookCount =>
      (_db.select('SELECT COUNT(*) AS c FROM `$_table`').first['c'] as int?) ?? 0;

  int get minOrder =>
      (_db.select('select min(`order`) as m from `$_table`').first['m'] as int?) ?? 0;

  int get maxOrder =>
      (_db.select('select max(`order`) as m from `$_table`').first['m'] as int?) ?? 0;

  Book? getBook(String bookUrl) {
    final rows = _db.select('SELECT * FROM `$_table` WHERE bookUrl = ?', [bookUrl]);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  Book? getBookByNameAuthor(String name, String author) {
    final rows = _db.select(
      'SELECT * FROM `$_table` WHERE name = ? and author = ?',
      [name, author],
    );
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  Book? getBookByOrigin(String name, String origin) {
    final rows = _db.select(
      'SELECT * FROM `$_table` WHERE name = ? and origin = ?',
      [name, origin],
    );
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  Book? getBookByFileName(String fileName) {
    final rows =
        _db.select('select * from `$_table` where originName = ?', [fileName]);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  /// 按详情页地址取书（书源搜索结果转正式书籍时用它查重）。
  Book? getByUrl(String bookUrl) {
    final rows = _db.select('select * from `$_table` where bookUrl = ?', [bookUrl]);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  /// 书的对外整数 ID = SQLite `rowid`。
  ///
  /// 表主键是 `bookUrl`（TEXT），而契约里的 `bookId` 是 int。两者需要一个映射，
  /// 用 rowid 而不是另加自增列，是为了不改 Room 兼容的 22 张表结构。
  int? idOf(String bookUrl) {
    final rows = _db.select(
      'select rowid as rid from `$_table` where bookUrl = ?',
      [bookUrl],
    );
    return rows.isEmpty ? null : rows.first['rid'] as int;
  }

  Book? getById(int id) {
    final rows = _db.select('select * from `$_table` where rowid = ?', [id]);
    return rows.isEmpty ? null : Book.fromRow(rows.first);
  }

  /// 书架列表：只含在架书，按 `order` + 最近阅读时间排。
  ///
  /// `group` 是位域：分组 ID 用 `(group & id) > 0` 命中（Kotlin 的语义），
  /// `groupID=0` 表示全部。试读书（`type & notShelf`）不进列表。
  List<(int id, Book book)> shelfBooks(int groupId) {
    final byGroup = groupId > 0 ? ' and (`group` & ?) > 0' : '';
    final args = <Object?>[BookType.notShelf];
    if (groupId > 0) args.add(groupId);
    return _db
        .select(
          'select rowid as rid, * from `$_table` '
          'where (type & ?) = 0$byGroup '
          'order by `order` asc, durChapterTime desc',
          args,
        )
        .map((row) => (row['rid'] as int, Book.fromRow(row)))
        .toList();
  }

  List<Book> findByName(List<String> names) {
    if (names.isEmpty) return const [];
    final placeholders = List.filled(names.length, '?').join(', ');
    return _db
        .select('SELECT * FROM `$_table` WHERE `name` in ($placeholders)', names)
        .map((r) => Book.fromRow(r))
        .toList();
  }

  /// 分组位域命中：`group & :group > 0`。
  List<Book> getBooksByGroup(int group) => _db
      .select('SELECT * FROM `$_table` WHERE (`group` & ?) > 0', [group])
      .map((r) => Book.fromRow(r))
      .toList();

  List<Book> getWebBooks() => _db
      .select('SELECT * FROM `$_table` where type & ? = 0', [BookType.local])
      .map((r) => Book.fromRow(r))
      .toList();

  List<Book> getHasUpdateBooks() => _db
      .select(
        'SELECT * FROM `$_table` where type & ? = 0 and canUpdate = 1',
        [BookType.local],
      )
      .map((r) => Book.fromRow(r))
      .toList();

  List<Book> getByTypeOnLine(int type) => _db
      .select(
        'SELECT * FROM `$_table` where type & ? > 0 and type & ? = 0',
        [type, BookType.local],
      )
      .map((r) => Book.fromRow(r))
      .toList();

  List<Book> search(String key) => _db
      .select(
        "SELECT * FROM `$_table` WHERE name like '%'||?||'%' "
        "or author like '%'||?||'%'",
        [key, key],
      )
      .map((r) => Book.fromRow(r))
      .toList();

  /// 所有被书架实际使用的网文书源（与 `book_sources` 去重连接）。
  List<BookSource> getAllUseBookSource() => _db
      .select(
        'select distinct bs.* from books, book_sources bs '
        'where origin == bookSourceUrl and origin not like ? '
        'and origin not like ?',
        ['${BookType.localTag}%', '${BookType.webDavTag}%'],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  bool has(String bookUrl) {
    final row = _db.select(
      'select exists(select 1 from `$_table` where bookUrl = ?) as e',
      [bookUrl],
    ).first;
    return (row['e'] as int) != 0;
  }

  bool hasBook(String name, String author) {
    final row = _db.select(
      'select exists(select 1 from `$_table` where name = ? and author = ?) as e',
      [name, author],
    ).first;
    return (row['e'] as int) != 0;
  }

  bool hasFile(String fileName) {
    final row = _db.select(
      'select exists(select 1 from `$_table` where type & ? > 0 '
      'and (originName = ? or (origin != ? and origin like ?))) as e',
      [BookType.local, fileName, BookType.localTag, '%$fileName'],
    ).first;
    return (row['e'] as int) != 0;
  }

  void insert(Book book) => _db.execute(_insertSql, _params(book));

  void insertAll(List<Book> books) {
    if (books.isEmpty) return;
    runInTransaction(_db, () {
      final stmt = _db.prepare(_insertSql);
      try {
        for (final book in books) {
          stmt.execute(_params(book));
        }
      } finally {
        stmt.close();
      }
    });
  }

  void update(Book book) {
    final row = book.toRow();
    final params = [
      for (final column in _columns.skip(1)) row[column],
      book.bookUrl,
    ];
    _db.execute(_updateSql, params);
  }

  void delete(Book book) => deleteByUrl(book.bookUrl);

  void deleteByUrl(String bookUrl) =>
      _db.execute('DELETE FROM `$_table` WHERE bookUrl = ?', [bookUrl]);

  void deleteNotShelfBooks() =>
      _db.execute('delete from `$_table` where type & ? > 0', [BookType.notShelf]);

  void upProgress(String bookUrl, int pos) => _db.execute(
        'update `$_table` set durChapterPos = ? where bookUrl = ?',
        [pos, bookUrl],
      );

  /// 一次更新章节位置四列（`Shelf.SaveProgress` 用）。
  ///
  /// 不用「读实体 → 改字段 → update(book)」：那条路径会把别的线程刚写的
  /// 分组/标题一并覆盖回去，而进度保存是阅读过程中最高频的写操作。
  void updateProgress(
    int id, {
    required int chapterIndex,
    required String chapterTitle,
    required int chapterPos,
    required int chapterTime,
  }) =>
      _db.execute(
        'update `$_table` set durChapterIndex = ?, durChapterTitle = ?, '
        'durChapterPos = ?, durChapterTime = ? where rowid = ?',
        [chapterIndex, chapterTitle, chapterPos, chapterTime, id],
      );

  void upGroup(int oldGroupId, int newGroupId) => _db.execute(
        'update `$_table` set `group` = ? where `group` = ?',
        [newGroupId, oldGroupId],
      );

  void removeGroup(int group) => _db.execute(
        'update `$_table` set `group` = `group` - ? where `group` & ? > 0',
        [group, group],
      );
}
