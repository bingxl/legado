import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `ruleSubs` 表访问。
class RuleSubDao {
  RuleSubDao(this._db);

  final Database _db;

  static const String _table = RuleSub.tableRuleSubs;

  static const String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(`id`, `name`, `url`, `type`, `customOrder`, `autoUpdate`, `update`) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)';

  List<RuleSub> get all => _db
      .select('select * from `$_table` order by customOrder')
      .map((r) => RuleSub.fromRow(r))
      .toList();

  int get maxOrder {
    final rows =
        _db.select('select customOrder from `$_table` order by customOrder limit 0,1');
    return rows.isEmpty ? 0 : rows.first['customOrder'] as int;
  }

  RuleSub? findByUrl(String url) {
    final rows = _db.select('select * from `$_table` where url = ?', [url]);
    return rows.isEmpty ? null : RuleSub.fromRow(rows.first);
  }

  void insert(RuleSub sub) => _db.execute(
        _insertSql,
        [sub.id, sub.name, sub.url, sub.type, sub.customOrder, boolToInt(sub.autoUpdate), sub.update],
      );

  void update(RuleSub sub) => _db.execute(
        'update `$_table` set name = ?, url = ?, type = ?, customOrder = ?, '
        'autoUpdate = ?, `update` = ? where id = ?',
        [sub.name, sub.url, sub.type, sub.customOrder, boolToInt(sub.autoUpdate), sub.update, sub.id],
      );

  void delete(RuleSub sub) => _db.execute('delete from `$_table` where id = ?', [sub.id]);
}
