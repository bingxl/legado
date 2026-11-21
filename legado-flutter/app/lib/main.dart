import 'package:flutter/material.dart';

import 'core/bridge/legado_client.dart';
import 'core/router/routes.dart';
import 'core/theme/app_theme.dart';
import 'features/book/book_detail_page.dart';
import 'features/explore/explore_page.dart';
import 'features/explore/explore_show_page.dart';
import 'features/me/me_page.dart';
import 'features/reader/comic_reader_page.dart';
import 'features/reader/pdf_reader_page.dart';
import 'features/reader/reader_page.dart';
import 'features/rss/rss_article_page.dart';
import 'features/rss/rss_favorite_page.dart';
import 'features/rss/rss_home_page.dart';
import 'features/rss/rss_source_edit_page.dart';
import 'features/search/search_page.dart';
import 'features/shelf/webdav_page.dart';
import 'features/settings/reader_settings_page.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/settings_store.dart';
import 'features/settings/theme_settings_page.dart';
import 'features/shell/home_shell.dart';
import 'features/source/source_debug_page.dart';
import 'features/source/source_edit_page.dart';
import 'features/source/source_list_page.dart';
import 'features/source/source_login_page.dart';
import 'features/tools/bookmark_page.dart';
import 'features/tools/cache_page.dart';
import 'features/tools/record_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String? bootError;
  try {
    await LegadoClient.connect();
    // 配置在启动时就拉一次：阅读器打开时要同步拿到字号/背景，
    // 等到点进阅读页再去请求，第一页必然先按默认值排版再跳一次，会闪。
    // 失败不影响启动——各页面用默认值，设置页自己会重试。
    try {
      await SettingsStore.instance.load();
    } catch (_) {}
  } on LegadoError catch (e) {
    bootError = '${e.code}: ${e.message}';
  } catch (e) {
    bootError = '$e';
  }

  runApp(LegadoApp(bootError: bootError));
}

class LegadoApp extends StatelessWidget {
  const LegadoApp({super.key, this.bootError});

  /// 已接线的路由（其余走占位页）。
  static const _implemented = <String>{
    RouteNames.me,
    RouteNames.explore,
    RouteNames.exploreDetail,
    RouteNames.search,
    RouteNames.bookDetail,
    RouteNames.reader,
    RouteNames.sourceList,
    RouteNames.sourceEdit,
    RouteNames.sourceDebug,
    RouteNames.sourceLogin,
    RouteNames.rss,
    RouteNames.rssFavorite,
    RouteNames.rssSourceEdit,
    RouteNames.rssRead,
    RouteNames.settings,
    RouteNames.readerSettings,
    RouteNames.themeSettings,
    RouteNames.cache,
    RouteNames.bookmark,
    RouteNames.readRecord,
    RouteNames.webdav,
  };

  /// 内核初始化失败时的提示。为空表示初始化成功。
  final String? bootError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Legado',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      home: bootError == null
          ? const HomeShell()
          : _BootErrorPage(message: bootError!),
      routes: {
        // 已实现的页面显式接在这里；其余仍走占位页，保证任一入口可达。
        RouteNames.me: (_) => const MePage(),
        RouteNames.explore: (_) => const ExplorePage(),
        RouteNames.exploreDetail: (ctx) => ExploreShowPage.fromRouteArguments(
          ModalRoute.of(ctx)?.settings.arguments,
        ),
        RouteNames.search: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return SearchPage(initialSourceId: (map['sourceId'] as num?)?.toInt());
        },
        RouteNames.bookDetail: (ctx) => BookDetailPage.fromRouteArguments(
          ModalRoute.of(ctx)?.settings.arguments,
        ),
        RouteNames.reader: (ctx) {
          // 本地 PDF 走平台渲染页；本地漫画走逐页取图；其余是文字阅读器。
          // kind 由书架点击时带过来，缺席时按文字书处理。
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const <String, Object?>{};
          final kind = '${map['kind'] ?? ''}'.toLowerCase();
          if (kind == 'pdf') {
            return PdfReaderPage.fromRouteArguments(args);
          }
          if (map['localComic'] == true) {
            return ComicReaderPage.fromRouteArguments(args);
          }
          return ReaderPage.fromRouteArguments(args);
        },
        RouteNames.sourceList: (_) => const SourceListPage(),
        RouteNames.sourceEdit: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return SourceEditPage(sourceId: (map['sourceId'] as num?)?.toInt());
        },
        RouteNames.sourceDebug: (_) => const SourceDebugPage(),
        RouteNames.sourceLogin: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return SourceLoginPage(sourceId: (map['sourceId'] as num?)?.toInt() ?? 0);
        },
        RouteNames.rss: (_) => const RssHomePage(),
        RouteNames.rssFavorite: (_) => const RssFavoritePage(),
        RouteNames.rssSourceEdit: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return RssSourceEditPage(
            sourceId: (map['sourceId'] as num?)?.toInt(),
          );
        },
        RouteNames.rssRead: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return RssArticlePage(
            articleId: (map['articleId'] as num?)?.toInt() ?? 0,
            title: map['title'] as String?,
            content: map['content'] as String?,
            link: map['link'] as String?,
            favorite: map['favorite'] == true,
            sourceName: map['sourceName'] as String?,
          );
        },
        RouteNames.settings: (_) => const SettingsPage(),
        RouteNames.readerSettings: (_) => const ReaderSettingsPage(),
        RouteNames.themeSettings: (_) => const ThemeSettingsPage(),
        RouteNames.cache: (_) => const CachePage(),
        RouteNames.bookmark: (_) => const BookmarkPage(),
        RouteNames.readRecord: (_) => const RecordPage(),
        RouteNames.webdav: (_) => const WebDavPage(),
        for (final name in routeTitles.keys)
          if (name != RouteNames.shelf && !_implemented.contains(name))
            name: (ctx) => buildPlaceholderRoute(ctx, name),
      },
    );
  }
}

class _BootErrorPage extends StatelessWidget {
  const _BootErrorPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.link_off, size: 40, color: scheme.error),
                const SizedBox(height: 16),
                Text('内核初始化失败', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 20),
                // 内核与 UI 在同一进程里，不存在「先启动服务再开界面」这回事。
                // 走到这里只会是数据目录/数据库层面的故障，提示也要对准它。
                const Text('内核与应用运行在同一进程，无需单独启动任何服务。'),
                const SizedBox(height: 8),
                const Text('常见原因：数据目录不可写、磁盘已满、数据库损坏。'),
                const SizedBox(height: 8),
                SelectableText(
                  '换数据目录：--dart-define=LEGADO_HOME=<路径>',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () async {
                    try {
                      await LegadoClient.connect();
                      if (context.mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const HomeShell()),
                        );
                      }
                    } catch (_) {}
                  },
                  child: const Text('重试初始化'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
