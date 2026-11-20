import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `dictRules` 表访问。
class DictRuleDao {
  DictRuleDao(this._db);

  final Database _db;

  static const String _table = DictRule.tableDictRules;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` '
      '(`name`, `urlRule`, `showRule`, `enabled`, `sortNumber`) VALUES (?, ?, ?, ?, ?)';

  List<DictRule> get all => _db
      .select('select * from `$_table` order by sortNumber')
      .map((r) => DictRule.fromRow(r))
      .toList();

  List<DictRule> get enabled => _db
      .select('select * from `$_table` where enabled = 1 order by sortNumber')
      .map((r) => DictRule.fromRow(r))
      .toList();

  DictRule? getByName(String name) {
    final rows = _db.select('select * from `$_table` where name = ?', [name]);
    return rows.isEmpty ? null : DictRule.fromRow(rows.first);
  }

  void insert(DictRule rule) => _db.execute(
        _insertSql,
        [rule.name, rule.urlRule, rule.showRule, boolToInt(rule.enabled), rule.sortNumber],
      );

  void update(DictRule rule) => _db.execute(
        'update `$_table` set urlRule = ?, showRule = ?, enabled = ?, '
        'sortNumber = ? where name = ?',
        [rule.urlRule, rule.showRule, boolToInt(rule.enabled), rule.sortNumber, rule.name],
      );

  void delete(DictRule rule) =>
      _db.execute('delete from `$_table` where name = ?', [rule.name]);
}
