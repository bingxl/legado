import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `book_sources` 表 + `book_sources_part` 视图访问。
class BookSourceDao {
  BookSourceDao(this._db);

  final Database _db;

  static const String _table = BookSource.tableBookSources;
  static const String _part = BookSourcePart.viewBookSourcesPart;

  static const List<String> _columns = [
    'bookSourceUrl',
    'bookSourceName',
    'bookSourceGroup',
    'bookSourceType',
    'bookUrlPattern',
    'customOrder',
    'enabled',
    'enabledExplore',
    'jsLib',
    'enabledCookieJar',
    'concurrentRate',
    'header',
    'loginUrl',
    'loginUi',
    'loginCheckJs',
    'coverDecodeJs',
    'bookSourceComment',
    'variableComment',
    'lastUpdateTime',
    'respondTime',
    'weight',
    'exploreUrl',
    'exploreScreen',
    'ruleExplore',
    'searchUrl',
    'ruleSearch',
    'ruleBookInfo',
    'ruleToc',
    'ruleContent',
    'ruleReview',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(BookSource source) {
    final row = source.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<BookSource> get all =>
      _db.select('select * from `$_table` order by customOrder asc').map((r) => BookSource.fromRow(r)).toList();

  List<BookSourcePart> get allPart =>
      _db.select('select * from `$_part` order by customOrder asc').map((r) => BookSourcePart.fromRow(r)).toList();

  List<BookSource> get allEnabled => _db
      .select('select * from `$_table` where enabled = 1 order by customOrder')
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSourcePart> get allEnabledPart => _db
      .select('select * from `$_part` where enabled = 1 order by customOrder asc')
      .map((r) => BookSourcePart.fromRow(r))
      .toList();

  List<BookSource> get allDisabled => _db
      .select('select * from `$_table` where enabled = 0 order by customOrder')
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSource> get allEnabledExplore => _db
      .select('select * from `$_table` where enabledExplore = 1 order by customOrder')
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSource> get allLogin => _db
      .select("select * from `$_table` where loginUrl is not null and loginUrl != ''")
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSource> get allNoGroup => _db
      .select(
        "select * from `$_table` where bookSourceGroup is null or bookSourceGroup = '' "
        "or bookSourceGroup like '%未分组%'",
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  int allCount() =>
      (_db.select('select count(*) as c from `$_table`').first['c'] as int?) ?? 0;

  int get minOrder =>
      (_db.select('select min(customOrder) as m from `$_table`').first['m'] as int?) ?? 0;

  int get maxOrder =>
      (_db.select('select max(customOrder) as m from `$_table`').first['m'] as int?) ?? 0;

  /// 按 Url 取完整书源。
  BookSource? getBookSource(String key) {
    final rows = _db.select('select * from `$_table` where bookSourceUrl = ?', [key]);
    return rows.isEmpty ? null : BookSource.fromRow(rows.first);
  }

  /// 契约里的 `id`：`book_sources` 没有 int 主键，映射到 SQLite 隐式 rowid。
  ///
  /// `update` 不改 rowid；删除后重新导入会变。用到 int id 的地方必须成对使用。
  int? rowIdOf(String key) {
    final rows = _db.select(
      'select rowid as id from `$_table` where bookSourceUrl = ?',
      [key],
    );
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  /// 按 rowid 批量取（`Source.Export` 的 ids 入参）。
  List<BookSource> getByRowIds(List<int> ids) {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    return _db
        .select(
          'select * from `$_table` where rowid in ($placeholders) '
          'order by customOrder asc',
          ids,
        )
        .map((r) => BookSource.fromRow(r))
        .toList();
  }

  BookSourcePart? getBookSourcePart(String key) {
    final rows = _db.select('select * from `$_part` where bookSourceUrl = ?', [key]);
    return rows.isEmpty ? null : BookSourcePart.fromRow(rows.first);
  }

  bool has(String key) {
    final row = _db.select(
      'SELECT EXISTS(select 1 from `$_table` where bookSourceUrl = ?) as e',
      [key],
    ).first;
    return (row['e'] as int) != 0;
  }

  /// 搜索书名/分组/Url/注释。
  List<BookSource> search(String searchKey) => _db
      .select(
        "select * from `$_table` "
        "where bookSourceName like '%' || ? || '%' "
        "or bookSourceGroup like '%' || ? || '%' "
        "or bookSourceUrl like '%' || ? || '%' "
        "or bookSourceComment like '%' || ? || '%' "
        "order by customOrder asc",
        [searchKey, searchKey, searchKey, searchKey],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  /// 分组精确匹配（分组列是逗号分隔的多值字符串）。
  List<BookSource> groupSearch(String group) => _db
      .select(
        'select * from `$_table` where bookSourceGroup = ? '
        "or bookSourceGroup like ? || ',%' "
        "or bookSourceGroup like '%,' || ? "
        "or bookSourceGroup like '%,' || ? || ',%' "
        'order by customOrder asc',
        [group, group, group, group],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  /// 模糊包含分组，对应 Kotlin `getByGroup`。
  List<BookSource> getByGroup(String group) => _db
      .select(
        "select * from `$_table` where bookSourceGroup like '%' || ? || '%' "
        'order by customOrder asc',
        [group],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSource> getEnabledByGroup(String group) => _db
      .select(
        'select * from `$_table` where enabled = 1 and (bookSourceGroup = ? '
        "or bookSourceGroup like ? || ',%' "
        "or bookSourceGroup like '%,' || ? "
        "or bookSourceGroup like '%,' || ? || ',%') "
        'order by customOrder asc',
        [group, group, group, group],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  List<BookSourcePart> getEnabledPartByGroup(String group) => _db
      .select(
        'select * from `$_part` where enabled = 1 and (bookSourceGroup = ? '
        "or bookSourceGroup like ? || ',%' "
        "or bookSourceGroup like '%,' || ? "
        "or bookSourceGroup like '%,' || ? || ',%') "
        'order by customOrder asc',
        [group, group, group, group],
      )
      .map((r) => BookSourcePart.fromRow(r))
      .toList();

  List<BookSource> getEnabledByType(int type) => _db
      .select(
        "select * from `$_table` where bookUrlPattern != 'NONE' "
        'and bookSourceType = ? order by customOrder asc',
        [type],
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  /// 「添加网址」第一级匹配：书源地址恰好等于书籍 URL 的域名（对齐 Kotlin
  /// `BookSourceDao.getBookSourceAddBook`）。
  BookSource? getBookSourceAddBook(String baseUrl) {
    final rows = _db.select(
      'select * from `$_table` where enabled = 1 and bookSourceUrl = ? '
      'order by customOrder asc limit 1',
      [baseUrl],
    );
    return rows.isEmpty ? null : BookSource.fromRow(rows.first);
  }

  /// 「添加网址」第二级匹配候选：启用了且配了非空、非 NONE 的 bookUrlPattern。
  /// 调用方再用 `RegExp(pattern).hasMatch(bookUrl)` 逐个精确匹配。
  List<BookSource> hasBookUrlPattern() => _db
      .select(
        "select * from `$_table` where enabled = 1 "
        "and bookUrlPattern is not null and trim(bookUrlPattern) <> '' "
        "and trim(bookUrlPattern) <> 'NONE' order by customOrder asc",
      )
      .map((r) => BookSource.fromRow(r))
      .toList();

  /// 未拆分过的分组原始值（可能含 `a,b` 这种复合值）。
  List<String> get allGroupsUnprocessed => _db
      .select(
        "select distinct bookSourceGroup from `$_table` where trim(bookSourceGroup) <> ''",
      )
      .map((r) => r['bookSourceGroup'] as String)
      .toList();

  List<String> get allEnabledGroupsUnprocessed => _db
      .select(
        "select distinct bookSourceGroup from `$_table` "
        "where enabled = 1 and trim(bookSourceGroup) <> ''",
      )
      .map((r) => r['bookSourceGroup'] as String)
      .toList();

  /// 拆分后的分组名（去重 + 排序）。
  List<String> allGroups() => _dealGroups(allGroupsUnprocessed);

  List<String> allEnabledGroups() => _dealGroups(allEnabledGroupsUnprocessed);

  List<String> _dealGroups(List<String> raw) {
    final groups = <String>{};
    for (final item in raw) {
      for (final group in item.split(splitGroupRegex)) {
        final trimmed = group.trim();
        if (trimmed.isNotEmpty) groups.add(trimmed);
      }
    }
    final list = groups.toList()..sort();
    return list;
  }

  void insert(BookSource source) => _db.execute(_insertSql, _params(source));

  void insertAll(List<BookSource> sources) {
    if (sources.isEmpty) return;
    runInTransaction(_db, () {
      final stmt = _db.prepare(_insertSql);
      try {
        for (final source in sources) {
          stmt.execute(_params(source));
        }
      } finally {
        stmt.close();
      }
    });
  }

  void update(BookSource source) {
    final row = source.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `bookSourceUrl` = ?',
      [
        for (final column in _columns.skip(1)) row[column],
        source.bookSourceUrl,
      ],
    );
  }

  void delete(BookSource source) => deleteByKey(source.bookSourceUrl);

  void deleteByKey(String key) =>
      _db.execute('delete from `$_table` where bookSourceUrl = ?', [key]);

  void deleteAllByKey(Iterable<String> keys) {
    runInTransaction(_db, () {
      for (final key in keys) {
        deleteByKey(key);
      }
    });
  }

  void enable(String bookSourceUrl, bool enable) => _db.execute(
        'update `$_table` set enabled = ? where bookSourceUrl = ?',
        [boolToInt(enable), bookSourceUrl],
      );

  void enableExplore(String bookSourceUrl, bool enable) => _db.execute(
        'update `$_table` set enabledExplore = ? where bookSourceUrl = ?',
        [boolToInt(enable), bookSourceUrl],
      );

  void upOrder(String bookSourceUrl, int customOrder) => _db.execute(
        'update `$_table` set customOrder = ? where bookSourceUrl = ?',
        [customOrder, bookSourceUrl],
      );

  void upGroup(String bookSourceUrl, String group) => _db.execute(
        'update `$_table` set bookSourceGroup = ? where bookSourceUrl = ?',
        [group, bookSourceUrl],
      );
}
