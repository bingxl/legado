import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../kernel/module.dart';
import '../kernel/registry.dart';
import 'dao/dao.dart';
import 'database.dart';

/// 所有 DAO 的集合。
///
/// 一次性构造，避免 StoreModule 上挂 21 个 `late` 字段；
/// DAO 本身无状态（只持有连接），重复构造也不会泄漏。
class StoreDaos {
  StoreDaos(this.db)
      : book = BookDao(db),
        chapter = BookChapterDao(db),
        bookSource = BookSourceDao(db),
        bookGroup = BookGroupDao(db),
        bookmark = BookmarkDao(db),
        readRecord = ReadRecordDao(db),
        replaceRule = ReplaceRuleDao(db),
        cache = CacheDao(db),
        searchBook = SearchBookDao(db),
        searchKeyword = SearchKeywordDao(db),
        rssSource = RssSourceDao(db),
        rssArticle = RssArticleDao(db),
        rssReadRecord = RssReadRecordDao(db),
        rssStar = RssStarDao(db),
        dictRule = DictRuleDao(db),
        httpTts = HttpTTSDao(db),
        ruleSub = RuleSubDao(db),
        server = ServerDao(db),
        txtTocRule = TxtTocRuleDao(db),
        cookie = CookieDao(db),
        keyboardAssist = KeyboardAssistDao(db),
        settings = SettingsDao(db),
        readingProgress = ReadingProgressDao(db),
        bookmarkItem = BookmarkItemDao(db),
        recordItem = RecordItemDao(db),
        chapterCache = ChapterCacheDao(db);

  /// 服务层做跨 DAO 事务时用。
  final Database db;

  final BookDao book;
  final BookChapterDao chapter;
  final BookSourceDao bookSource;
  final BookGroupDao bookGroup;
  final BookmarkDao bookmark;
  final ReadRecordDao readRecord;
  final ReplaceRuleDao replaceRule;
  final CacheDao cache;
  final SearchBookDao searchBook;
  final SearchKeywordDao searchKeyword;
  final RssSourceDao rssSource;
  final RssArticleDao rssArticle;
  final RssReadRecordDao rssReadRecord;
  final RssStarDao rssStar;
  final DictRuleDao dictRule;
  final HttpTTSDao httpTts;
  final RuleSubDao ruleSub;
  final ServerDao server;
  final TxtTocRuleDao txtTocRule;
  final CookieDao cookie;
  final KeyboardAssistDao keyboardAssist;
  final SettingsDao settings;
  final ReadingProgressDao readingProgress;

  /// 契约书签 / 换章流水（与 Kotlin 的 `bookmarks` / `readRecord` 并存）。
  final BookmarkItemDao bookmarkItem;
  final RecordItemDao recordItem;
  final ChapterCacheDao chapterCache;
}

/// 存储模块。
///
/// 负责打开数据库、跑迁移、把 DAO 暴露给后续的服务层。
/// 其它模块**不要**自己 `sqlite3.open`：多连接在 WAL 下虽然能跑，
/// 但会让 `busy_timeout` 与事务边界变得不可推理。
class StoreModule extends CoreModule {
  /// 当前进程内的实例。
  ///
  /// M3 的服务层需要拿 DAO，而 `buildModules()` 每轮都会 new 一个新实例；
  /// 用静态引用而不是全局单例对象，`close()` 后会被清空，热重启不会拿到旧连接。
  static StoreModule? instance;

  LegadoDatabase? _db;
  StoreDaos? _daos;

  @override
  String get name => 'store';

  LegadoDatabase get database {
    final db = _db;
    if (db == null) {
      throw StateError('store 模块尚未 migrate，数据库未打开');
    }
    return db;
  }

  StoreDaos get daos {
    final daos = _daos;
    if (daos == null) {
      throw StateError('store 模块尚未 migrate，DAO 未初始化');
    }
    return daos;
  }

  /// 数据库文件路径（诊断用，未打开时为 null）。
  String? get path => _db?.path;

  @override
  Future<void> migrate(LegadoContext ctx) async {
    final dir = Directory(ctx.homeDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final db = await LegadoDatabase.open(p.join(ctx.homeDir, 'legado.db'));
    _db = db;
    _daos = StoreDaos(db.db);
    instance = this;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    registry.method(
      'System.Database',
      (args) async => {
        'version': database.version,
        'path': database.path,
        'tables': database.tableRowCounts(),
      },
      doc: '数据库 schema 版本、文件路径与各表行数',
    );
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
    _daos = null;
    if (identical(instance, this)) {
      instance = null;
    }
  }
}
