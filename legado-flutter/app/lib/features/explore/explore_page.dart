import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';
import 'explore_results.dart';

/// 发现页用到的控制面方法。
///
/// `Api` 是共享冻结文件，没有的常量由 feature 自带（见 api.dart 顶部注释）。
class _Api {
  static const listSources = 'Source.ListExploreSources';
  static const kinds = 'Source.ExploreKinds';
  static const explore = 'Source.Explore';
  static const previewBook = 'Source.PreviewBook';
}

/// 发现页（对应原版 `ui/main/explore/ExploreFragment` + `ExploreShowActivity`）。
///
/// 交互按跨端的宽窄屏做了两套：
///   - 宽屏（≥720）：左侧书源/分类导航，右侧结果网格；
///   - 窄屏：顶部「书源下拉 + 分类 chip」，下面是结果网格。
///
/// 数据全部来自 core：书源列表、分类、书单都是 `Source.*` 的 dto，
/// Dart 侧只保留「当前选中的源/分类/页码」这类渲染临时状态。
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _sources = const [];
  List<Map<String, dynamic>> _kinds = const [];
  List<Map<String, dynamic>> _books = const [];

  int _sourceId = 0;
  int _kindIndex = -1;
  String _kindUrl = '';

  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _kindError;

  /// 正在通过 PreviewBook 打开的书（bookUrl），避免重复点击。
  String? _openingUrl;

  /// 请求序号：切源/换分类会自增，晚到的旧响应直接丢弃，防止串数据。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _bootstrap();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 320) _loadMore();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await LegadoClient.instance.callList(_Api.listSources);
      if (!mounted) return;
      setState(() {
        _sources = list;
        _loading = false;
      });
      if (list.isEmpty) return;
      await _selectSource(_idOf(list.first));
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  /// 切换书源：先解析分类（可能跑书源 JS），再拉第一页。
  Future<void> _selectSource(int id) async {
    final mySeq = ++_seq;
    setState(() {
      _sourceId = id;
      _kinds = const [];
      _kindIndex = -1;
      _kindUrl = '';
      _books = const [];
      _page = 0;
      _hasMore = true;
      _loading = true;
      _error = null;
      _kindError = null;
    });
    try {
      final kinds = await LegadoClient.instance.callList(_Api.kinds, [id]);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _kinds = kinds;
        if (kinds.isNotEmpty) {
          _kindIndex = 0;
          _kindUrl = '${kinds.first['url'] ?? ''}';
        }
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      // 分类解析失败不阻断书单：Explore 传空地址时引擎会退回首个分类。
      setState(() => _kindError = '分类加载失败：${e.message}');
    }
    await _loadFirstPage(mySeq);
  }

  Future<void> _selectKind(int index) async {
    if (index < 0 || index >= _kinds.length) return;
    final kind = _kinds[index];
    setState(() {
      _kindIndex = index;
      _kindUrl = '${kind['url'] ?? ''}';
      _books = const [];
      _page = 0;
      _hasMore = true;
    });
    await _loadFirstPage();
  }

  /// 拉第一页；[seq] 为空表示这是一次新的请求（刷新/换分类）。
  Future<void> _loadFirstPage([int? seq]) async {
    final mySeq = seq ?? ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await LegadoClient.instance
          .callList(_Api.explore, [_sourceId, _kindUrl, 1]);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _books = mergeResults(const [], data);
        _page = 1;
        _hasMore = data.isNotEmpty;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _sourceId == 0 || _error != null) {
      return;
    }
    final mySeq = _seq;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await LegadoClient.instance
          .callList(_Api.explore, [_sourceId, _kindUrl, next]);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _books = mergeResults(_books, data);
        _page = next;
        // 空页即到底：书源没有明确的「总页数」可问。
        _hasMore = data.isNotEmpty;
        _loadingMore = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      // 失败也停止自动翻页，避免滚动到底时反复重试同一个坏页码。
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      _toast('加载下一页失败：${e.message}');
    }
  }

  Future<void> _refresh() async {
    if (_sourceId == 0) {
      await _bootstrap();
      return;
    }
    await _loadFirstPage();
  }

  /// 打开书籍：先用 PreviewBook 入库拿到 bookId（试读态，不进书架），再进详情页。
  Future<void> _openBook(Map<String, dynamic> item) async {
    if (_openingUrl != null) return;
    final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
    if (bookUrl.isEmpty) {
      _toast('这条结果没有书籍链接，无法打开');
      return;
    }
    setState(() => _openingUrl = bookUrl);
    try {
      final brief = await LegadoClient.instance.call(_Api.previewBook, [
        _sourceId,
        bookUrl,
        '${item['name'] ?? ''}',
        '${item['author'] ?? ''}',
        '${item['variable'] ?? ''}',
      ]);
      if (!mounted) return;
      final map = brief is Map<String, dynamic> ? brief : const <String, dynamic>{};
      final bookId = (map['id'] as num?)?.toInt() ?? 0;
      if (bookId == 0) {
        _toast('打开书籍失败：没有拿到书籍 ID');
        return;
      }
      Navigator.pushNamed(
        context,
        RouteNames.bookDetail,
        arguments: {
          'bookId': bookId,
          'bookName': '${map['name'] ?? item['name'] ?? ''}',
        },
      );
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('打开书籍失败：${e.message}');
    } finally {
      if (mounted) setState(() => _openingUrl = null);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static int _idOf(Map<String, dynamic> source) =>
      (source['id'] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, RouteNames.search),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 720) {
            return Row(
              children: [
                SizedBox(width: 232, child: _sidePanel()),
                const VerticalDivider(width: 0.6),
                Expanded(child: _resultsPane()),
              ],
            );
          }
          return Column(
            children: [
              _compactBar(),
              const Divider(height: 0.6),
              Expanded(child: _resultsPane()),
            ],
          );
        },
      ),
    );
  }

  // ── 宽屏左侧导航 ────────────────────────────────────────────

  Widget _sidePanel() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('书源', style: theme.textTheme.labelMedium),
        ),
        Expanded(flex: 3, child: _sourceList()),
        const Divider(height: 0.6),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('分类', style: theme.textTheme.labelMedium),
        ),
        Expanded(flex: 2, child: _kindList()),
      ],
    );
  }

  Widget _sourceList() {
    if (_sources.isEmpty) {
      return const Center(
        child: Text('暂无书源', style: TextStyle(fontSize: 12)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: _sources.length,
      itemBuilder: (_, i) {
        final source = _sources[i];
        final selected = _idOf(source) == _sourceId;
        final group = '${source['group'] ?? ''}';
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          selectedTileColor: scheme.secondaryContainer,
          title: Text(
            '${source['name'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          subtitle: group.isEmpty
              ? null
              : Text(
                  group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
          onTap: () => _selectSource(_idOf(source)),
        );
      },
    );
  }

  Widget _kindList() {
    if (_kindError != null && _kinds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          _kindError!,
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (_kinds.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('该源没有分类，直接展示默认页面', style: TextStyle(fontSize: 11)),
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      itemCount: _kinds.length,
      itemBuilder: (_, i) {
        final selected = i == _kindIndex;
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          selected: selected,
          selectedTileColor: scheme.secondaryContainer,
          title: Text(
            '${_kinds[i]['title'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12.5),
          ),
          onTap: () => _selectKind(i),
        );
      },
    );
  }

  // ── 窄屏顶部选择器 ──────────────────────────────────────────

  Widget _compactBar() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    value: _sources.any((s) => _idOf(s) == _sourceId) ? _sourceId : null,
                    isExpanded: true,
                    hint: const Text('选择书源', style: TextStyle(fontSize: 13)),
                    items: [
                      for (final source in _sources)
                        DropdownMenuItem<int>(
                          value: _idOf(source),
                          child: Text(
                            '${source['name'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) _selectSource(value);
                    },
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _refresh,
              ),
            ],
          ),
          if (_kinds.isNotEmpty)
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _kinds.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ChoiceChip(
                  label: Text(
                    '${_kinds[i]['title'] ?? ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: i == _kindIndex,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => _selectKind(i),
                ),
              ),
            )
          else if (_kindError != null)
            Text(
              _kindError!,
              style: TextStyle(fontSize: 11, color: scheme.error),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  // ── 结果区 ─────────────────────────────────────────────────

  Widget _resultsPane() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_sources.isEmpty) {
      return _emptyState(
        icon: Icons.explore_off_outlined,
        message: '还没有开启「发现」的书源',
        actionLabel: '去书源管理',
        onAction: () => Navigator.pushNamed(context, RouteNames.sourceList),
      );
    }

    if (_error != null) {
      return _emptyState(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        actionLabel: '重试',
        onAction: _refresh,
      );
    }

    if (_books.isEmpty) {
      return _emptyState(
        icon: Icons.menu_book_outlined,
        message: '这个分类下还没有书',
        actionLabel: '刷新',
        onAction: _refresh,
      );
    }

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                childAspectRatio: 0.58,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: _books.length,
              itemBuilder: (_, i) {
                final book = _books[i];
                return _BookCard(
                  book: book,
                  opening: _openingUrl != null &&
                      _openingUrl == '${book['bookUrl'] ?? ''}',
                  onTap: () => _openBook(book),
                );
              },
            ),
          ),
          SliverToBoxAdapter(child: _footer()),
        ],
      ),
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!_hasMore) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
      );
    }
    return const SizedBox(height: 16);
  }

  Widget _emptyState({
    required IconData icon,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}

/// 结果卡片：封面用首字占位（core 的 `/img/` 数据面尚未接入）。
class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.book,
    required this.opening,
    required this.onTap,
  });

  final Map<String, dynamic> book;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final author = '${book['author'] ?? ''}';
    final kind = '${book['kind'] ?? ''}';
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: opening ? null : onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _CoverPlaceholder(name: '${book['name'] ?? ''}'),
                if (opening)
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.black38,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${book['name'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          Text(
            author.isEmpty ? (kind.isEmpty ? ' ' : kind) : author,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: scheme.primaryContainer,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(
          fontSize: 28,
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
