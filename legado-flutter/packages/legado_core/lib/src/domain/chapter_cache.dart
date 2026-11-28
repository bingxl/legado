import 'row_utils.dart';

/// 一章的离线缓存。
///
/// 键是 `bookUrl + 章节序号`，另存抓取时的章节 URL：目录更新后地址会变，
/// 比对 URL 不一致就视为未缓存（`missing` 范围据此补抓），只按序号比对
/// 会把换了地址的章节当成已有缓存，离线读到的是旧内容。
///
/// 漫画图片本体落在磁盘 `cache/chapter/<bookId>/<idx>/`，这里只存地址列表，
/// 与 Go 版一致：SQLite 不用来装几 MB 的二进制。
class CachedChapter {
  const CachedChapter({
    required this.bookUrl,
    required this.index,
    this.title = '',
    this.url = '',
    this.html = '',
    this.images = '[]',
    this.size = 0,
    this.createdAt = 0,
    this.expiresAt = 0,
  });

  static const String table = 'chapter_cache';

  /// 自动缓存的到期时间。[days] <= 0 返回 0（永久保留）。
  static int autoExpiresAt(int nowSeconds, int days) =>
      days > 0 ? nowSeconds + days * 86400 : 0;

  /// 这一行在 [nowSeconds] 时是否已经到期；0 表示永久。
  bool isExpiredAt(int nowSeconds) => expiresAt > 0 && expiresAt <= nowSeconds;

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `chapter_cache` (
  `bookUrl` TEXT NOT NULL,
  `idx` INTEGER NOT NULL,
  `title` TEXT NOT NULL DEFAULT '',
  `url` TEXT NOT NULL DEFAULT '',
  `html` TEXT NOT NULL DEFAULT '',
  `images` TEXT NOT NULL DEFAULT '[]',
  `size` INTEGER NOT NULL DEFAULT 0,
  `created_at` INTEGER NOT NULL DEFAULT 0,
  `expires_at` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`bookUrl`, `idx`),
  FOREIGN KEY(`bookUrl`) REFERENCES `books`(`bookUrl`) ON DELETE CASCADE
)''';

  final String bookUrl;
  final int index;
  final String title;
  final String url;
  final String html;

  /// JSON 数组字符串（本地可访问地址），避免给实体加 List 转换层。
  final String images;

  /// 字节数（正文按 UTF-8 计 + 图片文件大小之和）。
  final int size;

  /// Unix 秒，缓存管理页按它倒序。
  final int createdAt;

  /// 到期时间的 Unix 秒；0 = 永不过期（原版 `caches.deadline` 的语义）。
  ///
  /// 阅读时自动缓存（含预取）写「当前时间 + cache.expireDays 天」，
  /// 用户手动缓存写 0。启动与命中时按这一列判过期，不按 created_at
  /// 反推——否则手动缓存也会被自动清掉。
  final int expiresAt;

  factory CachedChapter.fromRow(Map<String, Object?> row) => CachedChapter(
        bookUrl: asString(row['bookUrl']),
        index: asInt(row['idx']),
        title: asString(row['title']),
        url: asString(row['url']),
        html: asString(row['html']),
        images: asString(row['images'], '[]'),
        size: asInt(row['size']),
        createdAt: asInt(row['created_at']),
        expiresAt: asInt(row['expires_at']),
      );

  Map<String, Object?> toRow() => <String, Object?>{
        'bookUrl': bookUrl,
        'idx': index,
        'title': title,
        'url': url,
        'html': html,
        'images': images,
        'size': size,
        'created_at': createdAt,
        'expires_at': expiresAt,
      };
}

/// 按书聚合的缓存概况（DAO 层的聚合结果，不是表）。
class CachedBookStats {
  const CachedBookStats({
    required this.bookUrl,
    required this.chapters,
    required this.size,
    required this.updatedAt,
  });

  final String bookUrl;
  final int chapters;
  final int size;

  /// 该书最近一次缓存的 Unix 秒。
  final int updatedAt;
}
