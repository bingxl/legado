import 'package:sqlite3/sqlite3.dart';

import '../domain/domain.dart';
import 'migration.dart';

/// 当前 schema 版本。
///
/// Android 版 Room 已演进到 65+，但那是**增量迁移链**。
/// 这里是 Flutter 版的全新初版：初始 schema 直接按实体生成，
/// 从 v1 开始重新计数，未来只在自己的迁移列表里递增。
const int schemaVersion = 1;

/// 所有建表语句，顺序 = 依赖顺序（books 必须早于 chapters / searchBooks）。
List<String> get createTableSqls => [
      Book.createSql,
      BookChapter.createSql,
      BookSource.createSql,
      BookGroup.createSql,
      Bookmark.createSql,
      ReadRecord.createSql,
      CachedChapter.createSql,
      ReplaceRule.createSql,
      Cache.createSql,
      SearchBook.createSql,
      SearchKeyword.createSql,
      RssSource.createSql,
      RssArticle.createSql,
      RssReadRecord.createSql,
      RssStar.createSql,
      DictRule.createSql,
      HttpTTS.createSql,
      RuleSub.createSql,
      Server.createSql,
      TxtTocRule.createSql,
      Cookie.createSql,
      KeyboardAssist.createSql,
      AppSetting.createSql,
      ReadingProgress.createSql,
      BookmarkItem.createSql,
      RecordItem.createSql,
    ];

/// 索引，照抄 Kotlin `@Entity(indices=[...])`。
///
/// 命名沿用 Room 的 `index_<表>_<列>`：将来若要做「从 Android 库导入」，
/// 索引名一致才能直接用 `ATTACH` + `INSERT SELECT` 而不必重建。
List<String> get createIndexSqls => [
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_books_name_author` '
          'ON `books` (`name`, `author`)',
      'CREATE INDEX IF NOT EXISTS `index_chapters_bookUrl` ON `chapters` (`bookUrl`)',
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_chapters_bookUrl_index` '
          'ON `chapters` (`bookUrl`, `index`)',
      'CREATE INDEX IF NOT EXISTS `index_book_sources_bookSourceUrl` '
          'ON `book_sources` (`bookSourceUrl`)',
      'CREATE INDEX IF NOT EXISTS `index_bookmarks_bookName_bookAuthor` '
          'ON `bookmarks` (`bookName`, `bookAuthor`)',
      'CREATE INDEX IF NOT EXISTS `index_replace_rules_id` ON `replace_rules` (`id`)',
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_caches_key` ON `caches` (`key`)',
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_searchBooks_bookUrl` '
          'ON `searchBooks` (`bookUrl`)',
      'CREATE INDEX IF NOT EXISTS `index_searchBooks_origin` ON `searchBooks` (`origin`)',
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_search_keywords_word` '
          'ON `search_keywords` (`word`)',
      'CREATE INDEX IF NOT EXISTS `index_rssSources_sourceUrl` ON `rssSources` (`sourceUrl`)',
      'CREATE UNIQUE INDEX IF NOT EXISTS `index_cookies_url` ON `cookies` (`url`)',
      BookmarkItem.createIndexSql,
      RecordItem.createTimeIndexSql,
      RecordItem.createBookIndexSql,
    ];

/// v1：初始建表。
///
/// 单独做成函数而不是在 [defaultMigrations] 里写闭包，
/// 是为了测试能「只建表不跑迁移」地对照 schema。
void _v1(Database db) {
  for (final sql in createTableSqls) {
    db.execute(sql);
  }
  db.execute(BookSourcePart.createSql);
  for (final sql in createIndexSqls) {
    db.execute(sql);
  }
}

/// 默认迁移链。
List<Migration> get defaultMigrations => [Migration(1, _v1)];

/// 所有表名（不含视图），供 `System.Database` 自检与测试使用。
const List<String> dataTableNames = [
  'books',
  'chapters',
  'book_sources',
  'book_groups',
  'bookmarks',
  'readRecord',
  'replace_rules',
  'caches',
  'searchBooks',
  'search_keywords',
  'rssSources',
  'rssArticles',
  'rssReadRecords',
  'rssStars',
  'dictRules',
  'httpTTS',
  'ruleSubs',
  'servers',
  'txtTocRules',
  'cookies',
  'keyboardAssists',
  'app_settings',
  'reading_progress',
  'bookmark',
  'read_record',
  'chapter_cache',
];
