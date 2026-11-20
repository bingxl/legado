import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `app_settings` 表访问。
///
/// 语义约定：
/// - 值一律字符串，数字/布尔由上层序列化；
/// - `put(key, null)` 等价删除；
/// - `removeAll([])` 等价清空全表。
class SettingsDao {
  SettingsDao(this._db);

  final Database _db;

  static const String _table = AppSetting.tableAppSettings;

  static const String _putSql =
      'INSERT OR REPLACE INTO `$_table` (`key`, `value`) VALUES (?, ?)';

  /// 全部非 null 设置，保持插入/覆盖后的自然顺序。
  Map<String, String> getAll() {
    final result = <String, String>{};
    for (final row in _db.select(
      'select `key`, `value` from `$_table` where value is not null',
    )) {
      result[row['key'] as String] = row['value'] as String;
    }
    return result;
  }

  String? get(String key) {
    final rows = _db.select('select `value` from `$_table` where `key` = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// 写入或删除（`value == null`）。
  Future<void> put(String key, String? value) async {
    if (value == null) {
      await remove(key);
      return;
    }
    _db.execute(_putSql, [key, value]);
  }

  /// 批量写入，单事务。
  ///
  /// `patch` 里值为 null 的键按删除处理；其余按 upsert。
  Future<void> putAll(Map<String, String?> patch) async {
    if (patch.isEmpty) return;
    runInTransaction(_db, () {
      for (final entry in patch.entries) {
        if (entry.value == null) {
          _db.execute('delete from `$_table` where `key` = ?', [entry.key]);
        } else {
          _db.execute(_putSql, [entry.key, entry.value]);
        }
      }
    });
  }

  /// 批量删除；`keys` 为空时清空全表。
  Future<void> removeAll(List<String> keys) async {
    if (keys.isEmpty) {
      await clear();
      return;
    }
    runInTransaction(_db, () {
      final stmt = _db.prepare('delete from `$_table` where `key` = ?');
      try {
        for (final key in keys) {
          stmt.execute([key]);
        }
      } finally {
        stmt.close();
      }
    });
  }

  Future<void> remove(String key) async {
    _db.execute('delete from `$_table` where `key` = ?', [key]);
  }

  Future<void> clear() async {
    _db.execute('delete from `$_table`');
  }

  int count() =>
      (_db.select('select count(*) as c from `$_table`').first['c'] as int?) ?? 0;
}
