import 'package:flutter/material.dart';

/// 路由常量。与原版 legado 的界面一一对应（见 docs/TECH-SELECTION.md §5）。
///
/// **冻结文件**：任何 feature 都不要修改本文件的常量名；
/// 新页面由 U00（壳层负责人）在合并时接入 [appRoutes]。
class RouteNames {
  RouteNames._();

  // 主框架（BottomNavigationView 四个 tab）
  static const shelf = '/';
  static const explore = '/explore';
  static const rss = '/rss';
  static const me = '/me';

  // 书籍
  static const shelfManage = '/shelf/manage';
  static const bookDetail = '/book';
  static const reader = '/read';
  static const search = '/search';
  static const exploreDetail = '/explore/detail';

  // 书源与规则
  static const sourceList = '/source';
  static const sourceEdit = '/source/edit';
  static const sourceDebug = '/source/debug';
  static const sourceLogin = '/source/login';
  static const sourceImport = '/source/import';
  static const replaceRule = '/replace-rule';
  static const txtTocRule = '/txt-toc-rule';

  // RSS
  static const rssSourceList = '/rss/source';
  static const rssSourceEdit = '/rss/source/edit';
  static const rssArticleList = '/rss/article';
  static const rssRead = '/rss/read';
  static const rssFavorite = '/rss/favorite';

  // 我的 / 设置 / 工具
  static const settings = '/settings';
  static const readerSettings = '/settings/reader';
  static const themeSettings = '/settings/theme';
  static const dictSettings = '/settings/dict';
  static const webdav = '/settings/webdav';
  static const about = '/about';
  static const cache = '/tools/cache';
  static const bookmark = '/tools/bookmark';
  static const readRecord = '/tools/record';
  static const fileManage = '/tools/file';

  // 朗读 / 听书
  static const tts = '/tts';
  static const audioPlayer = '/audio';
}

/// 路由标题（用于占位页与调试）。
const Map<String, String> routeTitles = {
  RouteNames.shelf: '书架',
  RouteNames.explore: '发现',
  RouteNames.rss: '订阅',
  RouteNames.me: '我的',
  RouteNames.bookDetail: '书籍详情',
  RouteNames.reader: '阅读',
  RouteNames.search: '搜索',
  RouteNames.exploreDetail: '发现分类',
  RouteNames.sourceList: '书源管理',
  RouteNames.sourceEdit: '编辑书源',
  RouteNames.sourceDebug: '书源调试',
  RouteNames.sourceLogin: '书源登录',
  RouteNames.sourceImport: '导入书源',
  RouteNames.replaceRule: '替换净化',
  RouteNames.txtTocRule: 'TXT 目录规则',
  RouteNames.rssSourceList: '订阅源',
  RouteNames.rssSourceEdit: '编辑订阅源',
  RouteNames.rssArticleList: '文章列表',
  RouteNames.rssRead: '文章正文',
  RouteNames.rssFavorite: '订阅收藏',
  RouteNames.settings: '设置',
  RouteNames.readerSettings: '阅读设置',
  RouteNames.themeSettings: '主题',
  RouteNames.dictSettings: '词典',
  RouteNames.webdav: 'WebDAV 备份',
  RouteNames.about: '关于',
  RouteNames.cache: '缓存管理',
  RouteNames.bookmark: '书签',
  RouteNames.readRecord: '阅读记录',
  RouteNames.fileManage: '文件管理',
  RouteNames.tts: '朗读',
  RouteNames.audioPlayer: '听书',
};

/// 尚未实现的页面统一用占位页，保证 28 条路由全部可达（W0 要求）。
/// 合并时把对应条目替换成真实页面即可，不影响其他分支。
Widget buildPlaceholderRoute(BuildContext context, String name) {
  return PlaceholderRoutePage(title: routeTitles[name] ?? name, route: name);
}

/// 占位页：显示路由名、标题与负责模块，便于并行开发时对照。
class PlaceholderRoutePage extends StatelessWidget {
  const PlaceholderRoutePage({super.key, required this.title, required this.route});

  final String title;
  final String route;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction_outlined, size: 40, color: scheme.outline),
            const SizedBox(height: 12),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(route, style: TextStyle(color: scheme.outline, fontSize: 12)),
            const SizedBox(height: 16),
            Text('该页面由对应 UI 模块实现', style: TextStyle(color: scheme.outline)),
          ],
        ),
      ),
    );
  }
}
