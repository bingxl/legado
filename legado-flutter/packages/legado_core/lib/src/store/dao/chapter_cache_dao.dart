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
      '`html`, `images`, `size`, `created_at`) VALUES (?, ?, ?, ?, ?, ?, ?, ?)';

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

  /// 删除超过 [days] 天的缓存，返回删除条数。
  ///
  /// 原版 Kotlin 的章节缓存**没有时间过期**，只有「目录 URL 变了视为失效」
  /// 与手动清理；这里的 TTL 是本实现的扩展，默认 0（永不过期）。
  int purgeExpired(int days, {int? nowSeconds}) {
    if (days <= 0) return 0;
    final now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final before = now - days * 86400;
    final rows = _db.select(
      'select count(*) as c from `$_table` '
      'where `created_at` > 0 and `created_at` < ?',
      [before],
    );
    final count = rows.isEmpty ? 0 : asInt(rows.first['c']);
    if (count > 0) {
      _db.execute(
        'delete from `$_table` where `created_at` > 0 and `created_at` < ?',
        [before],
      );
    }
    return count;
  }

  void clear() => _db.execute('delete from `$_table`');
}
