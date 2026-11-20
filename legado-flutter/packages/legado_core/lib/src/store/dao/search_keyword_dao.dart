import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `search_keywords` 表访问。
class SearchKeywordDao {
  SearchKeywordDao(this._db);

  final Database _db;

  static const String _table = SearchKeyword.tableSearchKeywords;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` (`word`, `usage`, `lastUseTime`) VALUES (?, ?, ?)';

  List<SearchKeyword> get all =>
      _db.select('SELECT * FROM `$_table`').map((r) => SearchKeyword.fromRow(r)).toList();

  List<SearchKeyword> byUsage() => _db
      .select('SELECT * FROM `$_table` ORDER BY usage DESC')
      .map((r) => SearchKeyword.fromRow(r))
      .toList();

  List<SearchKeyword> byTime() => _db
      .select('SELECT * FROM `$_table` ORDER BY lastUseTime DESC')
      .map((r) => SearchKeyword.fromRow(r))
      .toList();

  List<SearchKeyword> search(String key) => _db
      .select(
        "SELECT * FROM `$_table` where word like '%'||?||'%' ORDER BY usage DESC",
        [key],
      )
      .map((r) => SearchKeyword.fromRow(r))
      .toList();

  SearchKeyword? get(String key) {
    final rows = _db.select('select * from `$_table` where word = ?', [key]);
    return rows.isEmpty ? null : SearchKeyword.fromRow(rows.first);
  }

  void insert(SearchKeyword keyword) =>
      _db.execute(_insertSql, [keyword.word, keyword.usage, keyword.lastUseTime]);

  void update(SearchKeyword keyword) => _db.execute(
        'update `$_table` set usage = ?, lastUseTime = ? where word = ?',
        [keyword.usage, keyword.lastUseTime, keyword.word],
      );

  void delete(SearchKeyword keyword) =>
      _db.execute('delete from `$_table` where word = ?', [keyword.word]);

  void deleteAll() => _db.execute('DELETE FROM `$_table`');
}
