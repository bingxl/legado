import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `rssSources` 表访问。
class RssSourceDao {
  RssSourceDao(this._db);

  final Database _db;

  static const String _table = RssSource.tableRssSources;

  static const List<String> _columns = [
    'sourceUrl',
    'sourceName',
    'sourceIcon',
    'sourceGroup',
    'sourceComment',
    'enabled',
    'variableComment',
    'jsLib',
    'enabledCookieJar',
    'concurrentRate',
    'header',
    'loginUrl',
    'loginUi',
    'loginCheckJs',
    'coverDecodeJs',
    'sortUrl',
    'singleUrl',
    'articleStyle',
    'ruleArticles',
    'ruleNextPage',
    'ruleTitle',
    'rulePubDate',
    'ruleDescription',
    'ruleImage',
    'ruleLink',
    'ruleContent',
    'contentWhitelist',
    'contentBlacklist',
    'shouldOverrideUrlLoading',
    'style',
    'enableJs',
    'loadWithBaseUrl',
    'injectJs',
    'lastUpdateTime',
    'customOrder',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(RssSource source) {
    final row = source.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<RssSource> get all => _db
      .select('SELECT * FROM `$_table` order by customOrder')
      .map((r) => RssSource.fromRow(r))
      .toList();

  int get size =>
      (_db.select('select count(sourceUrl) as c from `$_table`').first['c'] as int?) ?? 0;

  int get minOrder =>
      (_db.select('select min(customOrder) as m from `$_table`').first['m'] as int?) ?? 0;

  int get maxOrder =>
      (_db.select('select max(customOrder) as m from `$_table`').first['m'] as int?) ?? 0;

  List<RssSource> get noGroup => _db
      .select("select * from `$_table` where sourceGroup is null or sourceGroup = ''")
      .map((r) => RssSource.fromRow(r))
      .toList();

  List<String> get allGroupsUnprocessed => _db
      .select("select distinct sourceGroup from `$_table` where trim(sourceGroup) <> ''")
      .map((r) => r['sourceGroup'] as String)
      .toList();

  RssSource? getByKey(String key) {
    final rows = _db.select('select * from `$_table` where sourceUrl = ?', [key]);
    return rows.isEmpty ? null : RssSource.fromRow(rows.first);
  }

  List<RssSource> getRssSources(List<String> sourceUrls) {
    if (sourceUrls.isEmpty) return const [];
    final placeholders = List.filled(sourceUrls.length, '?').join(', ');
    return _db
        .select('select * from `$_table` where sourceUrl in ($placeholders)', sourceUrls)
        .map((r) => RssSource.fromRow(r))
        .toList();
  }

  bool has(String key) {
    final row = _db.select(
      'select exists(select 1 from `$_table` where sourceUrl = ?) as e',
      [key],
    ).first;
    return (row['e'] as int) != 0;
  }

  List<RssSource> search(String key) => _db
      .select(
        "SELECT * FROM `$_table` where sourceName like '%' || ? || '%' "
        "or sourceUrl like '%' || ? || '%' "
        "or sourceGroup like '%' || ? || '%' "
        "or sourceComment like '%' || ? || '%' "
        'order by customOrder',
        [key, key, key, key],
      )
      .map((r) => RssSource.fromRow(r))
      .toList();

  List<RssSource> groupSearch(String key) => _db
      .select(
        'SELECT * FROM `$_table` where (sourceGroup = ? '
        "or sourceGroup like ? || ',%' "
        "or sourceGroup like '%,' || ? "
        "or sourceGroup like '%,' || ? || ',%') "
        'order by customOrder',
        [key, key, key, key],
      )
      .map((r) => RssSource.fromRow(r))
      .toList();

  List<RssSource> getByGroup(String group) => _db
      .select("select * from `$_table` where sourceGroup like '%' || ? || '%'", [group])
      .map((r) => RssSource.fromRow(r))
      .toList();

  List<String> allGroups() => _dealGroups(allGroupsUnprocessed);

  List<String> _dealGroups(List<String> raw) {
    final groups = <String>{};
    for (final item in raw) {
      for (final group in item.split(splitGroupRegex)) {
        final trimmed = group.trim();
        if (trimmed.isNotEmpty) groups.add(trimmed);
      }
    }
    return groups.toList()..sort();
  }

  void insert(RssSource source) => _db.execute(_insertSql, _params(source));

  void insertAll(List<RssSource> sources) {
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

  void update(RssSource source) {
    final row = source.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `sourceUrl` = ?',
      [for (final column in _columns.skip(1)) row[column], source.sourceUrl],
    );
  }

  void delete(RssSource source) => deleteByKey(source.sourceUrl);

  void deleteByKey(String sourceUrl) =>
      _db.execute('delete from `$_table` where sourceUrl = ?', [sourceUrl]);

  /// 清空内置订阅源（分组名包含 `legado`）。
  void deleteDefault() =>
      _db.execute("delete from `$_table` where sourceGroup like 'legado'");

  void enable(String sourceUrl, bool enable) => _db.execute(
        'update `$_table` set enabled = ? where sourceUrl = ?',
        [boolToInt(enable), sourceUrl],
      );
}
