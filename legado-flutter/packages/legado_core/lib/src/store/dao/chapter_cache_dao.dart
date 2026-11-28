import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../database.dart';

/// `chapter_cache` 表访问。
class ChapterCacheDao {
  ChapterCacheDao(this._db);

  final Database _db;

  static const String _table = CachedChapter.table;

  static const String _upsertSql =
      'INSERT OR REPLACE INTO `$_table` (`bookUrl`, `idx`, `title`, `url`, '
      '`html`, `images`, `size`, `created_at`, `expires_at`) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)';

  CachedChapter? get(String bookUrl, int index) {
    final rows = _db.select(
      'select * from `$_table` where `bookUrl` = ? and `idx` = ?',
      [bookUrl, index],
    );
    return rows.isEmpty ? null : CachedChapter.fromRow(rows.first);
  }

  void put(CachedChapter chapter) => _db.execute(_upsertSql, [
        chapter.bookUrl,
        chapter.index,
        chapter.title,
        chapter.url,
        chapter.html,
        chapter.images,
        chapter.size,
        chapter.createdAt,
        chapter.expiresAt,
      ]);

  List<int> indexes(String bookUrl) {
    final rows = _db.select(
      'select `idx` from `$_table` where `bookUrl` = ? order by `idx`',
      [bookUrl],
    );
    return [for (final row in rows) (row['idx'] as num).toInt()];
  }

  List<CachedChapter> ofBook(String bookUrl) {
    final rows = _db.select(
      'select * from `$_table` where `bookUrl` = ? order by `idx`',
      [bookUrl],
    );
    return [for (final row in rows) CachedChapter.fromRow(row)];
  }

  List<CachedBookStats> bookStats() {
    final rows = _db.select(
      'select `bookUrl`, count(*) as c, sum(`size`) as s, max(`created_at`) as t '
      'from `$_table` group by `bookUrl` order by t desc',
    );
    return [
      for (final row in rows)
        CachedBookStats(
          bookUrl: asString(row['bookUrl']),
          chapters: asInt(row['c']),
          size: asInt(row['s']),
          updatedAt: asInt(row['t']),
        ),
    ];
  }

  /// 已缓存章数；[freshUrls] 非空时只算 URL 仍匹配的章节。
  ///
  /// 目录改版后章节 URL 会变，只按序号数会把 stale 缓存算进去。
  int freshCount(String bookUrl, Map<int, String> freshUrls) {
    final rows = _db.select(
      'select `idx`, `url` from `$_table` where `bookUrl` = ?',
      [bookUrl],
    );
    var count = 0;
    for (final row in rows) {
      final index = (row['idx'] as num).toInt();
      final cachedUrl = asString(row['url']);
      if (freshUrls[index] == cachedUrl) count++;
    }
    return count;
  }

  /// 按章节删除，返回删除条数。
  int delete(String bookUrl, List<int> indexes) {
    if (indexes.isEmpty) return 0;
    var removed = 0;
    runInTransaction(_db, () {
      for (final index in indexes) {
        _db.execute(
          'delete from `$_table` where `bookUrl` = ? and `idx` = ?',
          [bookUrl, index],
        );
        removed += 1;
      }
    });
    return removed;
  }

  void deleteByBook(String bookUrl) =>
      _db.execute('delete from `$_table` where `bookUrl` = ?', [bookUrl]);

  /// 已到期的缓存行（供服务层同步清理磁盘图片）。
  ///
  /// 判据是每行自己的 `expires_at`：> 0 且 <= now 才算到期；
  /// `expires_at = 0` 的手动缓存**永不**到期（原版 `caches.deadline` 语义）。
  /// 不再按 `created_at` + 全局天数反推，否则手动缓存也会被自动清掉。
  ///
  /// 只删 SQLite 会让 `<home>/cache/chapter/<id>/<idx>/` 的图片变成孤儿：
  /// 目录仍在、下次缓存同章时旧图「复活」。所以过期清理必须先把行查出来，
  /// 由调用方删完磁盘再调 [purgeExpired] 删行。
  List<CachedChapter> expired({int? nowSeconds}) {
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = _db.select(
      'select * from `$_table` '
      'where `expires_at` > 0 and `expires_at` <= ?',
      [now],
    );
    return [for (final row in rows) CachedChapter.fromRow(row)];
  }

  /// 删除已到期的行，返回删除条数。
  ///
  /// 只负责数据库；磁盘图片由调用方配合 [expired] 清理（见 ReaderService）。
  int purgeExpired({int? nowSeconds}) {
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final rows = _db.select(
      'select count(*) as c from `$_table` '
      'where `expires_at` > 0 and `expires_at` <= ?',
      [now],
    );
    final count = rows.isEmpty ? 0 : asInt(rows.first['c']);
    if (count > 0) {
      _db.execute(
        'delete from `$_table` where `expires_at` > 0 and `expires_at` <= ?',
        [now],
      );
    }
    return count;
  }

  void clear() => _db.execute('delete from `$_table`');
}
