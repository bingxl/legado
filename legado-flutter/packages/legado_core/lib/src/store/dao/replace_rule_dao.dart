import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `replace_rules` 表访问。
class ReplaceRuleDao {
  ReplaceRuleDao(this._db);

  final Database _db;

  static const String _table = ReplaceRule.tableReplaceRules;

  static const List<String> _columns = [
    'id',
    'name',
    'group',
    'pattern',
    'replacement',
    'scope',
    'scopeTitle',
    'scopeContent',
    'excludeScope',
    'isEnabled',
    'isRegex',
    'timeoutMillisecond',
    'sortOrder',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(ReplaceRule rule) {
    final row = rule.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<ReplaceRule> get all => _db
      .select('SELECT * FROM `$_table` ORDER BY sortOrder ASC')
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  List<ReplaceRule> get allEnabled => _db
      .select('SELECT * FROM `$_table` WHERE isEnabled = 1 ORDER BY sortOrder ASC')
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  List<ReplaceRule> get noGroup => _db
      .select(
        "select * from `$_table` where `group` is null or `group` = ''",
      )
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  List<String> get allGroupsUnprocessed => _db
      .select("select distinct `group` from `$_table` where trim(`group`) <> ''")
      .map((r) => r['group'] as String)
      .toList();

  int get minOrder =>
      (_db.select('SELECT MIN(sortOrder) as m FROM `$_table`').first['m'] as int?) ?? 0;

  int get maxOrder =>
      (_db.select('SELECT MAX(sortOrder) as m FROM `$_table`').first['m'] as int?) ?? 0;

  /// 未启用的条数。
  int get disabledCount =>
      (_db.select('SELECT COUNT(*) - SUM(isEnabled) as c FROM `$_table`').first['c']
              as int?) ??
      0;

  ReplaceRule? findById(int id) {
    final rows = _db.select('SELECT * FROM `$_table` WHERE id = ?', [id]);
    return rows.isEmpty ? null : ReplaceRule.fromRow(rows.first);
  }

  List<ReplaceRule> findByIds(List<int> ids) {
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(', ');
    return _db
        .select('SELECT * FROM `$_table` WHERE id in ($placeholders)', ids)
        .map((r) => ReplaceRule.fromRow(r))
        .toList();
  }

  List<ReplaceRule> findEnabledByContentScope(String name, String origin) => _db
      .select(
        "SELECT * FROM `$_table` WHERE isEnabled = 1 and scopeContent = 1 "
        "AND (scope LIKE '%' || ? || '%' or scope LIKE '%' || ? || '%' "
        "or scope is null or scope = '') "
        "and (excludeScope is null or (excludeScope not LIKE '%' || ? || '%' "
        "and excludeScope not LIKE '%' || ? || '%')) "
        'order by sortOrder',
        [name, origin, name, origin],
      )
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  List<ReplaceRule> findEnabledByTitleScope(String name, String origin) => _db
      .select(
        "SELECT * FROM `$_table` WHERE isEnabled = 1 and scopeTitle = 1 "
        "AND (scope LIKE '%' || ? || '%' or scope LIKE '%' || ? || '%' "
        "or scope is null or scope = '') "
        "and (excludeScope is null or (excludeScope not LIKE '%' || ? || '%' "
        "and excludeScope not LIKE '%' || ? || '%')) "
        'order by sortOrder',
        [name, origin, name, origin],
      )
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  List<ReplaceRule> getByGroup(String group) => _db
      .select("select * from `$_table` where `group` like '%' || ? || '%'", [group])
      .map((r) => ReplaceRule.fromRow(r))
      .toList();

  void insert(ReplaceRule rule) {
    // Kotlin 的 id 默认是 System.currentTimeMillis()（autoGenerate）；
    // 调用方没显式给 id 时这里补一个，避免所有规则都落在 id=0 上互相覆盖。
    final fixed = rule.id == 0
        ? rule.copyWith(id: DateTime.now().millisecondsSinceEpoch)
        : rule;
    _db.execute(_insertSql, _params(fixed));
  }

  void update(ReplaceRule rule) {
    final row = rule.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `id` = ?',
      [for (final column in _columns.skip(1)) row[column], rule.id],
    );
  }

  void delete(ReplaceRule rule) =>
      _db.execute('delete from `$_table` where id = ?', [rule.id]);

  void enableAll(bool enable) => _db.execute(
        'UPDATE `$_table` SET isEnabled = ?',
        [boolToInt(enable)],
      );

  List<String> allGroups() {
    final groups = <String>{};
    for (final item in allGroupsUnprocessed) {
      for (final group in item.split(splitGroupRegex)) {
        final trimmed = group.trim();
        if (trimmed.isNotEmpty) groups.add(trimmed);
      }
    }
    return groups.toList()..sort();
  }
}
