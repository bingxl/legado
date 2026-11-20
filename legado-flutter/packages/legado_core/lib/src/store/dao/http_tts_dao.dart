import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `httpTTS` 表访问。
class HttpTTSDao {
  HttpTTSDao(this._db);

  final Database _db;

  static const String _table = HttpTTS.tableHttpTts;

  static const List<String> _columns = [
    'id',
    'name',
    'url',
    'contentType',
    'concurrentRate',
    'loginUrl',
    'loginUi',
    'header',
    'jsLib',
    'enabledCookieJar',
    'loginCheckJs',
    'lastUpdateTime',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(HttpTTS tts) {
    final row = tts.toRow();
    return [for (final column in _columns) row[column]];
  }

  List<HttpTTS> get all => _db
      .select('select * from `$_table` order by name')
      .map((r) => HttpTTS.fromRow(r))
      .toList();

  int get count =>
      (_db.select('select count(*) as c from `$_table`').first['c'] as int?) ?? 0;

  HttpTTS? get(int id) {
    final rows = _db.select('select * from `$_table` where id = ?', [id]);
    return rows.isEmpty ? null : HttpTTS.fromRow(rows.first);
  }

  String? getName(int id) {
    final rows = _db.select('select name from `$_table` where id = ?', [id]);
    return rows.isEmpty ? null : rows.first['name'] as String?;
  }

  void insert(HttpTTS tts) => _db.execute(_insertSql, _params(tts));

  void update(HttpTTS tts) {
    final row = tts.toRow();
    _db.execute(
      'UPDATE `$_table` SET '
      '${_columns.skip(1).map((c) => '`$c` = ?').join(', ')} '
      'WHERE `id` = ?',
      [for (final column in _columns.skip(1)) row[column], tts.id],
    );
  }

  void delete(HttpTTS tts) => _db.execute('delete from `$_table` where id = ?', [tts.id]);

  void deleteDefault() => _db.execute('delete from `$_table` where id < 0');
}
