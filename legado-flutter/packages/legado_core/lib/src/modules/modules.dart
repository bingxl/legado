import '../kernel/module.dart';
import '../service/bookmark/bookmark_module.dart';
import '../service/cache/cache_module.dart';
import '../service/export/export_module.dart';
import '../service/library/library_module.dart';
import '../service/login/login_module.dart';
import '../service/reader/reader_module.dart';
import '../service/replacerule/replace_rule_module.dart';
import '../service/rss/rss_module.dart';
import '../service/source/source_fetch_module.dart';
import '../service/source/source_module.dart';
import '../service/setting/settings_module.dart';
import '../service/shelf/shelf_module.dart';
import '../service/tts/tts_module.dart';
import '../service/webdav/webdav_module.dart';
import '../store/store.dart';
import 'system_module.dart';

/// 唯一的装配点。
///
/// 新增一个域只改这里：加一行模块实例，方法、CLI 命令、HTTP 路由都会自动出现。
/// 反过来说，任何宿主（Flutter / CLI / 未来的桌面壳）都**不允许**自己注册方法 ——
/// 一旦破坏这条，两个宿主的能力就会开始漂移。
///
/// 顺序不重要（`LegadoCore` 会按 `dependsOn` 做拓扑排序），但保持「基础在前」
/// 的书写顺序便于人读：system → store → 各业务域。
List<CoreModule> buildModules() => [
  SystemModule(),
  StoreModule(),
  SettingsModule(),
  ShelfModule(),
  TtsModule(),
  ReaderModule(),
  BookmarkModule(),
  LibraryModule(),
  CacheModule(),
  ReplaceRuleModule(),
  SourceModule(),
  SourceFetchModule(),
  LoginModule(),
  RssModule(),
  WebDAVModule(),
  ExportModule(),
];
