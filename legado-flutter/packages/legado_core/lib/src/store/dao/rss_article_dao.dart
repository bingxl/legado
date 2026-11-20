import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';

/// `rssArticles` 表访问。
class RssArticleDao {
  RssArticleDao(this._db);

  final Database _db;

  static const String _table = RssArticle.tableRssArticles;

  static const List<String> _columns = [
    'origin',
    'sort',
    'title',
    'order',
    'link',
    'pubDate',
    'description',
    'content',
    'image',
    'group',
    'read',
    'variable',
  ];

  static final String _insertSql = 'INSERT OR REPLACE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  static final String _insertIgnoreSql = 'INSERT OR IGNORE INTO `$_table` '
      '(${_columns.map((c) => '`$c`').join(', ')}) '
      'VALUES (${List.filled(_columns.length, '?').join(', ')})';

  List<Object?> _params(RssArticle article) {
    final row = article.toRow();
    return [for (final column in _columns) row[column]];
  }

  /// 契约里的文章 id 是 rowid（复合主键 `(origin, link)` 没有单点键）。
  int? rowIdOf(String origin, String link) {
    final rows = _db.select(
      'select rowid as id from `$_table` where origin = ? and link = ?',
      [origin, link],
    );
    return rows.isEmpty ? null : (rows.first['id'] as num?)?.toInt();
  }

  (int, RssArticle)? getByRowId(int id) {
    final rows = _db.select('select rowid as id, * from `$_table` where rowid = ?', [id]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return ((row['id'] as num).toInt(), RssArticle.fromRow(row));
  }

  /// 带 rowid 的分页列表；[origin] 为空表示全部源。
  List<(int, RssArticle)> listWithRowId({
    String origin = '',
    bool onlyUnread = false,
    int offset = 0,
    int limit = 200,
  }) {
    final clauses = <String>[];
    final args = <Object?>[];
    if (origin.isNotEmpty) {
      clauses.add('origin = ?');
      args.add(origin);
    }
    if (onlyUnread) clauses.add('`read` = 0');
    final where = clauses.isEmpty ? '' : 'where ${clauses.join(' and ')}';
    final rows = _db.select(
      'select rowid as id, * from `$_table` $where '
      'order by `order` desc, rowid desc limit ? offset ?',
      [...args, limit, offset],
    );
    return [
      for (final row in rows)
        ((row['id'] as num).toInt(), RssArticle.fromRow(row)),
    ];
  }

  Map<String, int> unreadCountByOrigin() {
    final rows = _db.select(
      'select origin, count(*) as c from `$_table` where `read` = 0 group by origin',
    );
    return {for (final row in rows) asString(row['origin']): asInt(row['c'])};
  }

  RssArticle? get(String origin, String link) {
    final rows = _db.select(
      'select * from `$_table` where origin = ? and link = ?',
      [origin, link],
    );
    return rows.isEmpty ? null : RssArticle.fromRow(rows.first);
  }

  /// 左连 `rssReadRecords` 得到已读标记。
  List<RssArticle> byOriginSort(String origin, String sort) => _db
      .select(
        'select t1.link, t1.sort, t1.origin, t1.`order`, t1.title, t1.content, '
        't1.description, t1.image, t1.`group`, t1.pubDate, t1.variable, '
        'ifNull(t2.read, 0) as read '
        'from `$_table` as t1 left join rssReadRecords as t2 on t1.link = t2.record '
        'where origin = ? and sort = ? order by `order` desc',
        [origin, sort],
      )
      .map((r) => RssArticle.fromRow(r))
      .toList();

  void insert(RssArticle article) => _db.execute(_insertSql, _params(article));

  /// 追加：已存在的 `(origin, link)` 保留旧值。
  void append(RssArticle article) => _db.execute(_insertIgnoreSql, _params(article));

  void appendAll(List<RssArticle> articles) {
    if (articles.isEmpty) return;
    _db.execute('BEGIN IMMEDIATE');
    try {
      final stmt = _db.prepare(_insertIgnoreSql);
      try {
        for (final article in articles) {
          stmt.execute(_params(article));
        }
      } finally {
        stmt.close();
      }
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void update(RssArticle article) {
    final row = article.toRow();
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
        article.origin,
        article.link,
      ],
    );
  }

  void clearOld(String origin, String sort, int order) => _db.execute(
        'delete from `$_table` where origin = ? and sort = ? and `order` < ?',
        [origin, sort, order],
      );

  void updateOrigin(String origin, String oldOrigin) => _db.execute(
        'update `$_table` set origin = ? where origin = ?',
        [origin, oldOrigin],
      );

  void deleteByOrigin(String origin) =>
      _db.execute('delete from `$_table` where origin = ?', [origin]);
}
