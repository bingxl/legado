import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `keyboardAssists` 表访问。
class KeyboardAssistDao {
  KeyboardAssistDao(this._db);

  final Database _db;

  static const String _table = KeyboardAssist.tableKeyboardAssists;

  static const String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(`type`, `key`, `value`, `serialNo`) VALUES (?, ?, ?, ?)';

  List<KeyboardAssist> get all => _db
      .select('select * from `$_table` order by serialNo')
      .map((r) => KeyboardAssist.fromRow(r))
      .toList();

  List<KeyboardAssist> getByType(int type) => _db
      .select('select * from `$_table` where type = ? order by serialNo', [type])
      .map((r) => KeyboardAssist.fromRow(r))
      .toList();

  int get maxSerialNo =>
      (_db.select('select max(serialNo) as m from `$_table`').first['m'] as int?) ?? 0;

  void insert(KeyboardAssist assist) =>
      _db.execute(_insertSql, [assist.type, assist.key, assist.value, assist.serialNo]);

  void update(KeyboardAssist assist) => _db.execute(
        'update `$_table` set value = ?, serialNo = ? where type = ? and `key` = ?',
        [assist.value, assist.serialNo, assist.type, assist.key],
      );

  void delete(KeyboardAssist assist) => _db.execute(
        'delete from `$_table` where type = ? and `key` = ?',
        [assist.type, assist.key],
      );
}
