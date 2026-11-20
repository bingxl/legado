import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `book_groups` 表访问。
class BookGroupDao {
  BookGroupDao(this._db);

  final Database _db;

  static const String _table = BookGroup.tableBookGroups;

  static const List<String> _columns = [
    'groupId',
    'groupName',
    'cover',
    'order',
    'enableRefresh',
    'show',
    'bookSort',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(BookGroup group) {
    final row = group.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<BookGroup> get all => _db
      .select('select * from `$_table` order by `order`')
      .map((r) => BookGroup.fromRow(r))
      .toList();

  /// 只含用户创建的分组（groupId >= 0）。
  List<BookGroup> get selectable => _db
      .select('select * from `$_table` where groupId >= 0 order by `order`')
      .map((r) => BookGroup.fromRow(r))
      .toList();

  BookGroup? getById(int id) {
    final rows = _db.select('select * from `$_table` where groupId = ?', [id]);
    return rows.isEmpty ? null : BookGroup.fromRow(rows.first);
  }

  BookGroup? getByName(String groupName) {
    final rows =
        _db.select('select * from `$_table` where groupName = ?', [groupName]);
    return rows.isEmpty ? null : BookGroup.fromRow(rows.first);
  }

  /// 所有用户分组 id 的按位或，占用的位就是 1。
  int get idsSum =>
      (_db.select('SELECT sum(groupId) as s FROM `$_table` where groupId >= 0').first['s']
              as int?) ??
      0;

  int get maxOrder =>
      (_db.select('SELECT MAX(`order`) as m FROM `$_table` where groupId >= 0').first['m']
              as int?) ??
      0;

  bool get canAddGroup =>
      (_db.select(
                'select count(*) < 64 as c from `$_table` where groupId >= 0 '
                'or groupId == -9223372036854775808',
              ).first['c'] as int?) ==
      1;

  /// 取一个未占用的分组位。
  ///
  /// 从 2 起：契约里 1 是内置「全部」分组（UI 实际用 0 表示全部，不下发），
  /// 分给用户会让 `Shelf.ListGroups` 一建组就看不见它。
  int getUnusedId() {
    var id = 2;
    final sum = idsSum;
    while (id & sum != 0) {
      id = id << 1;
    }
    return id;
  }

  List<String> getGroupNames(int id) => _db
      .select(
        'select groupName from `$_table` where groupId > 0 and (groupId & ?) > 0',
        [id],
      )
      .map((r) => r['groupName'] as String)
      .toList();

  void insert(BookGroup group) => _db.execute(_insertSql, _params(group));

  void update(BookGroup group) {
    final row = group.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `groupId` = ?',
      [for (final column in _columns.skip(1)) row[column], group.groupId],
    );
  }

  void delete(BookGroup group) =>
      _db.execute('delete from `$_table` where groupId = ?', [group.groupId]);

  void enableGroup(int groupId) => _db.execute(
        'update `$_table` set `show` = 1 where groupId = ?',
        [groupId],
      );
}
