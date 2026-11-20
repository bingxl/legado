import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `caches` 表访问。
class CacheDao {
  CacheDao(this._db);

  final Database _db;

  static const String _table = Cache.tableCaches;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` (`key`, `value`, `deadline`) VALUES (?, ?, ?)';

  Cache? get(String key) {
    final rows = _db.select('select * from `$_table` where `key` = ?', [key]);
    return rows.isEmpty ? null : Cache.fromRow(rows.first);
  }

  /// 取未过期的值（`deadline = 0` 视为永不过期）。
  String? getValid(String key, int now) {
    final rows = _db.select(
      'select value from `$_table` where `key` = ? and (deadline = 0 or deadline > ?)',
      [key, now],
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  void insert(Cache cache) =>
      _db.execute(_insertSql, [cache.key, cache.value, cache.deadline]);

  void put(String key, String? value, {int deadline = 0}) =>
      insert(Cache(key: key, value: value, deadline: deadline));

  void delete(String key) => _db.execute('delete from `$_table` where `key` = ?', [key]);

  /// 删除一个前缀下的全部缓存（删书时清它的章节缓存）。
  ///
  /// 用 GLOB 而不是 LIKE：`_` 在 LIKE 里是单字符通配符，缓存键里恰好看得到它。
  void deleteByPrefix(String prefix) => _db.execute(
        'delete from `$_table` where `key` glob ?',
        ['$prefix*'],
      );

  /// 删除某个书源/订阅源的全部变量（`v_` / `userInfo_` / `loginHeader_` / `sourceVariable_`）。
  void deleteSourceVariables(String key) => _db.execute(
        "delete from `$_table` where `key` like 'v_' || ? || '_%' "
        "or `key` = 'userInfo_' || ? "
        "or `key` = 'loginHeader_' || ? "
        "or `key` = 'sourceVariable_' || ?",
        [key, key, key, key],
      );

  void clearDeadline(int now) =>
      _db.execute('delete from `$_table` where deadline > 0 and deadline < ?', [now]);
}
