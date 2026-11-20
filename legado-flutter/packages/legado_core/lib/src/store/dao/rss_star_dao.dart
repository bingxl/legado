import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `rssStars` 表访问。
class RssStarDao {
  RssStarDao(this._db);

  final Database _db;

  static const String _table = RssStar.tableRssStars;

  static const List<String> _columns = [
    'origin',
    'sort',
    'title',
    'starTime',
    'link',
    'pubDate',
    'description',
    'content',
    'image',
    'group',
    'variable',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(RssStar star) {
    final row = star.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<RssStar> get all => _db
      .select('select * from `$_table` order by starTime desc')
      .map((r) => RssStar.fromRow(r))
      .toList();

  List<String> groups() => _db
      .select('select `group` from `$_table` group by `group` order by `group`')
      .map((r) => r['group'] as String)
      .toList();

  List<RssStar> byGroup(String group) => _db
      .select(
        'select * from `$_table` where `group` = ? order by starTime desc',
        [group],
      )
      .map((r) => RssStar.fromRow(r))
      .toList();

  RssStar? get(String origin, String link) {
    final rows = _db.select(
      'select * from `$_table` where origin = ? and link = ?',
      [origin, link],
    );
    return rows.isEmpty ? null : RssStar.fromRow(rows.first);
  }

  void insert(RssStar star) => _db.execute(_insertSql, _params(star));

  void update(RssStar star) {
    final row = star.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns
          .where((c) => c != 'origin' && c != 'link')
          .map((c) => '`$c` = ?')
          .join(', ')} '
      'WHERE `origin` = ? and `link` = ?',
      [
        for (final column in _columns)
          if (column != 'origin' && column != 'link') row[column],
        star.origin,
        star.link,
      ],
    );
  }

  void updateOrigin(String origin, String oldOrigin) =>
      _db.execute('update `$_table` set origin = ? where origin = ?', [origin, oldOrigin]);

  void deleteByOrigin(String origin) =>
      _db.execute('delete from `$_table` where origin = ?', [origin]);

  void deleteOne(String origin, String link) => _db.execute(
        'delete from `$_table` where origin = ? and link = ?',
        [origin, link],
      );

  void deleteByGroup(String group) =>
      _db.execute('delete from `$_table` where `group` = ?', [group]);

  void deleteAll() => _db.execute('delete from `$_table`');
}
