import 'package:flutter/material.dart';

import 'core/bridge/legado_client.dart';
import 'core/router/routes.dart';
import 'core/theme/app_theme.dart';
import 'features/book/book_detail_page.dart';
import 'features/explore/explore_page.dart';
import 'features/me/me_page.dart';
import 'features/reader/reader_page.dart';
import 'features/rss/rss_article_page.dart';
import 'features/rss/rss_favorite_page.dart';
import 'features/rss/rss_home_page.dart';
import 'features/rss/rss_source_edit_page.dart';
import 'features/search/search_page.dart';
import 'features/settings/reader_settings_page.dart';
import 'features/settings/settings_page.dart';
import 'features/settings/settings_store.dart';
import 'features/settings/theme_settings_page.dart';
import 'features/shell/home_shell.dart';
import 'features/source/source_debug_page.dart';
import 'features/source/source_edit_page.dart';
import 'features/source/source_list_page.dart';
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
    RouteNames.search,
    RouteNames.bookDetail,
    RouteNames.reader,
    RouteNames.sourceList,
    RouteNames.sourceEdit,
    RouteNames.sourceDebug,
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
  };

  /// core 连接失败时的提示。为空表示已连上。
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
        RouteNames.search: (_) => const SearchPage(),
        RouteNames.bookDetail: (ctx) => BookDetailPage.fromRouteArguments(
          ModalRoute.of(ctx)?.settings.arguments,
        ),
        RouteNames.reader: (ctx) => ReaderPage.fromRouteArguments(
          ModalRoute.of(ctx)?.settings.arguments,
        ),
        RouteNames.sourceList: (_) => const SourceListPage(),
        RouteNames.sourceEdit: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return SourceEditPage(sourceId: (map['sourceId'] as num?)?.toInt());
        },
        RouteNames.sourceDebug: (_) => const SourceDebugPage(),
        RouteNames.rss: (_) => const RssHomePage(),
        RouteNames.rssFavorite: (_) => const RssFavoritePage(),
        RouteNames.rssSourceEdit: (ctx) {
          final args = ModalRoute.of(ctx)?.settings.arguments;
          final map = args is Map ? args : const {};
          return RssSourceEditPage(sourceId: (map['sourceId'] as num?)?.toInt());
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
                Text('无法连接 core', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 20),
                const Text('启动方式：'),
                const SizedBox(height: 4),
                SelectableText(
                  'legado serve -port 8580',
                  style: TextStyle(fontFamily: 'monospace', color: scheme.primary),
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
                  child: const Text('重试连接'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
