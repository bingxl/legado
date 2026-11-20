import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `cookies` 表访问。
class CookieDao {
  CookieDao(this._db);

  final Database _db;

  static const String _table = Cookie.tableCookies;

  static const String _insertSql =
      'INSERT OR REPLACE INTO `$_table` (`url`, `cookie`) VALUES (?, ?)';

  Cookie? get(String url) {
    final rows = _db.select('SELECT * FROM `$_table` Where url = ?', [url]);
    return rows.isEmpty ? null : Cookie.fromRow(rows.first);
  }

  /// OkHttp 风格的 Cookie（url 里带 `|` 分隔的字段）。
  List<Cookie> getOkHttpCookies() => _db
      .select("select * from `$_table` where url like '%|%'")
      .map((r) => Cookie.fromRow(r))
      .toList();

  void insert(Cookie cookie) => _db.execute(_insertSql, [cookie.url, cookie.cookie]);

  void update(Cookie cookie) => _db.execute(
        'update `$_table` set cookie = ? where url = ?',
        [cookie.cookie, cookie.url],
      );

  void delete(String url) => _db.execute('delete from `$_table` where url = ?', [url]);

  void deleteOkHttp() => _db.execute("delete from `$_table` where url like '%|%'");
}
