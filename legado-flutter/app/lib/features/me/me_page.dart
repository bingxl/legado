import 'package:flutter/material.dart';

import '../../core/router/routes.dart';
import '../tools/tools_api.dart';

/// 「我的」tab（对应原版 `ui/main/my/MyFragment`）。
///
/// 只做导航与概览：所有入口都走 [RouteNames] 里已注册的具名路由，
/// 这样壳层的路由表是唯一接线点，本页不需要 import 任何业务页面。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  String? _version;
  _Overview? _overview;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);

    // 三组请求互相独立，逐个兜错：任一失败不能影响其他数字和入口列表。
    final version = await _read<String>(() async {
      final info = await ToolsApi.systemInfo();
      final value = toolsStr(info['version']).trim();
      return value.isEmpty ? null : value;
    });
    final shelf = await _read<int>(
      () async => (await ToolsApi.shelfBooks()).length,
    );
    final cached = await _read<int>(
      () async => toolsInt((await ToolsApi.cacheStats())['chapters']),
    );
    final bookmarks = await _read<int>(
      () async => (await ToolsApi.bookmarks(0, 1000)).length,
    );

    if (!mounted) return;
    setState(() {
      _version = version;
      // 三个数字缺一不可：只显示到一个或两个会让用户以为其余是 0，
      // 宁可整行隐藏（版本号仍会显示「未知」，说明 core 没连上）。
      _overview = (shelf != null && cached != null && bookmarks != null)
          ? _Overview(shelf: shelf, cacheChapters: cached, bookmarks: bookmarks)
          : null;
      _loading = false;
    });
  }

  /// 失败返回 null 而不是抛错：概览区的语义是「有就显示」。
  Future<T?> _read<T>(Future<T?> Function() read) async {
    try {
      return await read();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _headerCard(),
            _section('内容', [
              _entry(
                icon: Icons.menu_book_outlined,
                label: '书源管理',
                route: RouteNames.sourceList,
              ),
              _entry(
                icon: Icons.auto_fix_high_outlined,
                label: '替换净化',
                route: RouteNames.replaceRule,
              ),
              _entry(icon: Icons.rss_feed, label: '订阅源', route: RouteNames.rss),
            ]),
            _section('我的数据', [
              _entry(
                icon: Icons.bookmark_border,
                label: '书签',
                route: RouteNames.bookmark,
              ),
              _entry(
                icon: Icons.history,
                label: '阅读记录',
                route: RouteNames.readRecord,
              ),
              _entry(
                icon: Icons.sd_storage_outlined,
                label: '缓存管理',
                route: RouteNames.cache,
              ),
              _entry(
                icon: Icons.folder_outlined,
                label: '文件管理',
                route: RouteNames.fileManage,
              ),
            ]),
            _section('设置', [
              _entry(
                icon: Icons.settings_outlined,
                label: '设置',
                route: RouteNames.settings,
              ),
              _entry(
                icon: Icons.translate,
                label: '词典',
                route: RouteNames.dictSettings,
              ),
              _entry(
                icon: Icons.cloud_upload_outlined,
                label: 'WebDAV 备份',
                route: RouteNames.webdav,
              ),
            ]),
            _section('其他', [
              _entry(
                icon: Icons.info_outline,
                label: '关于',
                route: RouteNames.about,
              ),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _headerCard() {
    final scheme = Theme.of(context).colorScheme;
    final version = _loading && _version == null ? '读取中…' : (_version ?? '未知');
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 2),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: scheme.primaryContainer.withValues(alpha: 0.45),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_stories_outlined, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                'Legado',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '版本 $version',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          if (_overview != null) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                _OverviewCell(value: '${_overview!.shelf}', label: '书架'),
                _OverviewCell(
                  value: '${_overview!.cacheChapters}',
                  label: '缓存章节',
                ),
                _OverviewCell(value: '${_overview!.bookmarks}', label: '书签'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> tiles) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.outline,
            ),
          ),
        ),
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const Divider(height: 0.6, indent: 52),
          tiles[i],
        ],
      ],
    );
  }

  Widget _entry({
    required IconData icon,
    required String label,
    required String route,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(label),
      trailing: Icon(Icons.chevron_right, size: 18, color: scheme.outline),
      onTap: () => Navigator.pushNamed(context, route),
    );
  }
}

class _Overview {
  const _Overview({
    required this.shelf,
    required this.cacheChapters,
    required this.bookmarks,
  });

  final int shelf;
  final int cacheChapters;
  final int bookmarks;
}

class _OverviewCell extends StatelessWidget {
  const _OverviewCell({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }
}
