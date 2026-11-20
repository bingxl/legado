import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `rssReadRecords` 表访问。
class RssReadRecordDao {
  RssReadRecordDao(this._db);

  final Database _db;

  static const String _table = RssReadRecord.tableRssReadRecords;

  static const String _insertSql =
      'INSERT OR IGNORE INTO `$_table` (`record`, `title`, `readTime`, `read`) '
      'VALUES (?, ?, ?, ?)';

  List<RssReadRecord> getRecords() => _db
      .select('select * from `$_table` order by readTime desc')
      .map((r) => RssReadRecord.fromRow(r))
      .toList();

  int get countRecords =>
      (_db.select('select count(1) as c from `$_table`').first['c'] as int?) ?? 0;

  void insertRecord(RssReadRecord record) => _db.execute(
        _insertSql,
        [record.record, record.title, record.readTime, boolToInt(record.read)],
      );

  void deleteAllRecord() => _db.execute('delete from `$_table`');
}
