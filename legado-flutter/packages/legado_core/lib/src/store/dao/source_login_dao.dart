import 'package:sqlite3/sqlite3.dart';

import '../../domain/source_login.dart';

/// `source_login` 表访问。
class SourceLoginDao {
  SourceLoginDao(this._db);

  final Database _db;

  static const String _table = SourceLoginRecord.tableSourceLogins;

  SourceLoginRecord? get(String bookSourceUrl) {
    final rows = _db.select(
      'SELECT * FROM `$_table` WHERE `bookSourceUrl` = ?',
      [bookSourceUrl],
    );
    return rows.isEmpty ? null : SourceLoginRecord.fromRow(rows.first);
  }

  void put(SourceLoginRecord record) {
    _db.execute(
      'INSERT OR REPLACE INTO `$_table` (`bookSourceUrl`, `header`, `info`, `updatedAt`) '
      'VALUES (?, ?, ?, ?)',
      [record.bookSourceUrl, record.header, record.info, record.updatedAt],
    );
  }

  void delete(String bookSourceUrl) {
    _db.execute('DELETE FROM `$_table` WHERE `bookSourceUrl` = ?', [bookSourceUrl]);
  }

  /// 只清登录回执，保留粘贴的请求头（`Clear(withForm=false)` 用）。
  void clearInfo(String bookSourceUrl) {
    _db.execute(
      'UPDATE `$_table` SET `info` = \'\', `updatedAt` = ? WHERE `bookSourceUrl` = ?',
      [DateTime.now().millisecondsSinceEpoch, bookSourceUrl],
    );
  }
}
