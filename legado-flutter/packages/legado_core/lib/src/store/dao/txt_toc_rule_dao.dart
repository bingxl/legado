import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `txtTocRules` 表访问。
class TxtTocRuleDao {
  TxtTocRuleDao(this._db);

  final Database _db;

  static const String _table = TxtTocRule.tableTxtTocRules;

  static const String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(`id`, `name`, `rule`, `example`, `serialNumber`, `enable`) '
      'VALUES (?, ?, ?, ?, ?, ?)';

  List<TxtTocRule> get all => _db
      .select('select * from `$_table` order by serialNumber')
      .map((r) => TxtTocRule.fromRow(r))
      .toList();

  List<TxtTocRule> get enabled => _db
      .select('select * from `$_table` where enable = 1 order by serialNumber')
      .map((r) => TxtTocRule.fromRow(r))
      .toList();

  List<TxtTocRule> get disabled => _db
      .select('select * from `$_table` where enable != 1 order by serialNumber')
      .map((r) => TxtTocRule.fromRow(r))
      .toList();

  int get count =>
      (_db.select('select count(*) as c from `$_table`').first['c'] as int?) ?? 0;

  int get minOrder =>
      (_db.select('select ifNull(min(serialNumber), 0) as m from `$_table`').first['m']
              as int?) ??
      0;

  int get maxOrder =>
      (_db.select('select ifNull(max(serialNumber), 0) as m from `$_table`').first['m']
              as int?) ??
      0;

  TxtTocRule? get(int id) {
    final rows = _db.select('select * from `$_table` where id = ?', [id]);
    return rows.isEmpty ? null : TxtTocRule.fromRow(rows.first);
  }

  void insert(TxtTocRule rule) => _db.execute(
        _insertSql,
        [rule.id, rule.name, rule.rule, rule.example, rule.serialNumber, boolToInt(rule.enable)],
      );

  void update(TxtTocRule rule) => _db.execute(
        'update `$_table` set name = ?, rule = ?, example = ?, serialNumber = ?, '
        'enable = ? where id = ?',
        [rule.name, rule.rule, rule.example, rule.serialNumber, boolToInt(rule.enable), rule.id],
      );

  void delete(TxtTocRule rule) =>
      _db.execute('delete from `$_table` where id = ?', [rule.id]);

  void deleteDefault() => _db.execute('delete from `$_table` where id < 0');
}
