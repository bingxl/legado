import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `readRecord` 表访问。
class ReadRecordDao {
  ReadRecordDao(this._db);

  final Database _db;

  static const String _table = ReadRecord.tableReadRecord;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` (`deviceId`, `bookName`, `readTime`, `lastRead`) '
      'VALUES (?, ?, ?, ?)';

  List<ReadRecord> get all =>
      _db.select('select * from `$_table`').map((r) => ReadRecord.fromRow(r)).toList();

  /// 按书聚合：总时长 + 最后阅读时间。
  List<ReadRecordShow> get allShow => _db
      .select(
        'select bookName, sum(readTime) as readTime, max(lastRead) as lastRead '
        'from `$_table` group by bookName order by bookName collate localized',
      )
      .map((r) => ReadRecordShow.fromRow(r))
      .toList();

  int get allTime =>
      (_db.select('select sum(readTime) as s from `$_table`').first['s'] as int?) ?? 0;

  List<ReadRecordShow> search(String searchKey) => _db
      .select(
        "select bookName, sum(readTime) as readTime, max(lastRead) as lastRead "
        "from `$_table` where bookName like '%' || ? || '%' "
        'group by bookName order by bookName collate localized',
        [searchKey],
      )
      .map((r) => ReadRecordShow.fromRow(r))
      .toList();

  int? getReadTimeByBook(String bookName) =>
      _db.select('select sum(readTime) as s from `$_table` where bookName = ?', [bookName])
          .first['s'] as int?;

  int? getReadTime(String deviceId, String bookName) {
    final rows = _db.select(
      'select readTime from `$_table` where deviceId = ? and bookName = ?',
      [deviceId, bookName],
    );
    return rows.isEmpty ? null : rows.first['readTime'] as int?;
  }

  void insert(ReadRecord record) =>
      _db.execute(_insertSql, [record.deviceId, record.bookName, record.readTime, record.lastRead]);

  void update(ReadRecord record) => _db.execute(
        'update `$_table` set readTime = ?, lastRead = ? '
        'where deviceId = ? and bookName = ?',
        [record.readTime, record.lastRead, record.deviceId, record.bookName],
      );

  void delete(ReadRecord record) => _db.execute(
        'delete from `$_table` where deviceId = ? and bookName = ?',
        [record.deviceId, record.bookName],
      );

  void clear() => _db.execute('delete from `$_table`');

  void deleteByName(String bookName) =>
      _db.execute('delete from `$_table` where bookName = ?', [bookName]);
}
