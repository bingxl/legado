import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'rss_api.dart';
import 'rss_article_page.dart';
import 'rss_article_tile.dart';
import 'rss_favorite_page.dart';
import 'rss_source_edit_page.dart';
import 'rss_source_tab.dart';

/// 订阅首页（对应原版 `ui/main/rss/RssFragment` 的两个子页）。
///
/// 两个 tab 共用一份源列表：源列表决定文章 tab 的筛选项与未读数，
/// 所以由本页持有，源 tab 的任何改动都回调到这里重拉并广播。
class RssHomePage extends StatefulWidget {
  const RssHomePage({super.key});

  @override
  State<RssHomePage> createState() => _RssHomePageState();
}

class _RssHomePageState extends State<RssHomePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);

  List<Map<String, dynamic>> _sources = const [];
  String? _sourcesError;

  /// 文章 tab 的重拉信号：全量刷新、从收藏页返回时自增。
  int _revision = 0;

  bool _refreshingAll = false;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// tab 切换只影响 FAB 是否显示。
  void _onTabChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadSources() async {
    try {
      final list = await RssApi.listSources();
      if (!mounted) return;
      setState(() {
        _sources = list;
        _sourcesError = null;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() => _sourcesError = '${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _sourcesError = '$e');
    }
  }

  /// 刷新全部启用的源：core 的 Refresh(0) 就是「全部」语义。
  Future<void> _refreshAll() async {
    if (_refreshingAll) return;
    setState(() => _refreshingAll = true);
    try {
      final result = await RssApi.refreshArticles(0);
      final added = rssInt(result['added']);
      final updated = rssInt(result['updated']);
      final errors = (result['errors'] as List?) ?? const [];
      await _loadSources();
      if (!mounted) return;
      setState(() => _revision++);
      _toast(
        errors.isEmpty
            ? '刷新完成：新增 $added 篇，更新 $updated 篇'
            : '刷新完成（${errors.length} 个源失败）：新增 $added 篇',
      );
    } on LegadoError catch (e) {
      if (mounted) _toast('刷新失败：${e.message}');
    } catch (e) {
      if (mounted) _toast('刷新失败：$e');
    } finally {
      if (mounted) setState(() => _refreshingAll = false);
    }
  }

  Future<void> _openFavorites() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const RssFavoritePage()),
    );
    if (!mounted) return;
    // 收藏页里读文章会改已读态，源未读数与文章列表都要跟着变。
    setState(() => _revision++);
    await _loadSources();
  }

  Future<void> _openCreateSource() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const RssSourceEditPage()),
    );
    if (changed == true) await _loadSources();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅'),
        actions: [
          IconButton(
            tooltip: '订阅收藏',
            icon: const Icon(Icons.star_border),
            onPressed: _openFavorites,
          ),
          IconButton(
            tooltip: '刷新全部订阅',
            icon: _refreshingAll
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            onPressed: _refreshingAll ? null : _refreshAll,
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '文章'),
            Tab(text: '订阅源'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_sourcesError != null) _sourceErrorBar(),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                RssArticleTab(
                  sources: _sources,
                  revision: _revision,
                  onChanged: _loadSources,
                ),
                RssSourceTab(sources: _sources, onChanged: _loadSources),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: _tabs.index == 1
          ? FloatingActionButton(
              tooltip: '新增订阅源',
              onPressed: _openCreateSource,
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  /// 源列表加载失败时的提示条：article tab 仍可用（只有「全部」筛选）。
  Widget _sourceErrorBar() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 16, color: scheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '订阅源加载失败：$_sourcesError',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: _loadSources,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文章 tab：源筛选 + 只看未读 + 分页列表，下拉时对当前源触发一次抓取。
class RssArticleTab extends StatefulWidget {
  const RssArticleTab({
    super.key,
    required this.sources,
    required this.revision,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> sources;

  /// 外部要求重拉的信号（全量刷新 / 从收藏页返回）。
  final int revision;

  /// 已读状态变化后通知外层刷新源未读数。
  final Future<void> Function() onChanged;

  @override
  State<RssArticleTab> createState() => _RssArticleTabState();
}

class _RssArticleTabState extends State<RssArticleTab> {
  /// core 的 ListArticles 是 offset/limit，一页 20 条。
  static const int _pageSize = 20;

  final ScrollController _scroll = ScrollController();

  List<Map<String, dynamic>> _articles = const [];
  int _sourceId = 0;
  bool _unreadOnly = false;

  int _offset = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 请求序号：换源/换筛选会自增，晚到的旧响应直接丢弃。
  int _seq = 0;

  int get _totalUnread => widget.sources.fold<int>(
        0,
        (sum, source) => sum + rssInt(source['unreadCount']),
      );

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadFirstPage();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RssArticleTab old) {
    super.didUpdateWidget(old);
    if (widget.revision != old.revision) {
      _loadFirstPage(silent: true);
      return;
    }
    // 当前筛选项的源被删掉了：退回全部，否则列表永远是空的。
    final alive = widget.sources.map((s) => rssInt(s['id'])).toSet();
    if (_sourceId != 0 && !alive.contains(_sourceId)) {
      _sourceId = 0;
      _loadFirstPage(silent: true);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 400) _loadMore();
  }

  Future<void> _loadFirstPage({bool silent = false}) async {
    final mySeq = ++_seq;
    setState(() {
      if (!silent) _loading = true;
      _error = null;
    });
    try {
      final list = await RssApi.listArticles(
        sourceId: _sourceId,
        unreadOnly: _unreadOnly,
        offset: 0,
        limit: _pageSize,
      );
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _articles = list;
        _offset = list.length;
        _hasMore = list.length >= _pageSize;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _error != null) return;
    final mySeq = _seq;
    setState(() => _loadingMore = true);
    try {
      final list = await RssApi.listArticles(
        sourceId: _sourceId,
        unreadOnly: _unreadOnly,
        offset: _offset,
        limit: _pageSize,
      );
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _articles = [..._articles, ...list];
        _offset += list.length;
        // 空页即到底；core 不给总数。
        _hasMore = list.isNotEmpty;
        _loadingMore = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      // 失败也停止自动翻页，避免滚到底反复重试同一个坏页码。
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      _toast('加载下一页失败：${e.message}');
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      _toast('加载下一页失败：$e');
    }
  }

  void _selectSource(int id) {
    if (id == _sourceId) return;
    setState(() {
      _sourceId = id;
      _articles = const [];
      _offset = 0;
      _hasMore = true;
    });
    _loadFirstPage();
  }

  void _toggleUnreadOnly(bool value) {
    if (value == _unreadOnly) return;
    setState(() {
      _unreadOnly = value;
      _articles = const [];
      _offset = 0;
      _hasMore = true;
    });
    _loadFirstPage();
  }

  /// 下拉刷新：先让 core 去源站抓一次，再重读本地列表。
  /// 抓取失败也照样重读——本地已有的文章不应该因为网络问题看不见。
  Future<void> _refresh() async {
    String? error;
    var summary = '';
    try {
      final result = await RssApi.refreshArticles(_sourceId);
      final errors = (result['errors'] as List?) ?? const [];
      if (errors.isNotEmpty) error = '${errors.first}';
      summary = '新增 ${rssInt(result['added'])} 篇，更新 ${rssInt(result['updated'])} 篇';
    } on LegadoError catch (e) {
      error = '${e.code}: ${e.message}';
    } catch (e) {
      error = '$e';
    }
    await _loadFirstPage(silent: true);
    if (!mounted) return;
    await widget.onChanged();
    if (!mounted) return;
    _toast(error == null ? '刷新完成：$summary' : '刷新失败：$error');
  }

  Future<void> _openArticle(Map<String, dynamic> article) async {
    final id = rssInt(article['id']);
    final content = '${article['content'] ?? ''}'.trim().isNotEmpty
        ? '${article['content']}'
        : '${article['description'] ?? ''}';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RssArticlePage(
          articleId: id,
          title: '${article['title'] ?? ''}',
          content: content,
          link: '${article['link'] ?? ''}',
          favorite: article['favorite'] == true,
          pubDate: rssInt(article['pubDate']),
          sourceName: '${article['sourceName'] ?? ''}',
        ),
      ),
    );
    if (!mounted) return;
    if (_unreadOnly) {
      // 「只看未读」下这篇已经不该出现，重拉比本地剔除更准。
      await _loadFirstPage(silent: true);
    } else if (article['read'] != true) {
      setState(() {
        _articles = [
          for (final item in _articles)
            if (rssInt(item['id']) == id) {...item, 'read': true} else item,
        ];
      });
    }
    await widget.onChanged();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _filterBar(),
        const Divider(height: 0.6),
        Expanded(child: _content()),
      ],
    );
  }

  Widget _filterBar() {
    final chips = <Widget>[
      FilterChip(
        label: const Text('只看未读', style: TextStyle(fontSize: 12)),
        selected: _unreadOnly,
        visualDensity: VisualDensity.compact,
        onSelected: _toggleUnreadOnly,
      ),
      ChoiceChip(
        label: Text(
          _totalUnread > 0 ? '全部 ($_totalUnread)' : '全部',
          style: const TextStyle(fontSize: 12),
        ),
        selected: _sourceId == 0,
        visualDensity: VisualDensity.compact,
        onSelected: (_) => _selectSource(0),
      ),
      for (final source in widget.sources)
        ChoiceChip(
          label: Text(
            _sourceLabel(source),
            style: const TextStyle(fontSize: 12),
          ),
          selected: _sourceId == rssInt(source['id']),
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _selectSource(rssInt(source['id'])),
        ),
    ];

    return SizedBox(
      height: 50,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => chips[i],
      ),
    );
  }

  static String _sourceLabel(Map<String, dynamic> source) {
    final name = '${source['name'] ?? ''}'.trim();
    final label = name.isEmpty ? '未命名' : name;
    final unread = rssInt(source['unreadCount']);
    return unread > 0 ? '$label ($unread)' : label;
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _errorState();
    if (_articles.isEmpty) return _emptyState();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _articles.length + 1,
        separatorBuilder: (_, i) => i >= _articles.length - 1
            ? const SizedBox.shrink()
            : const Divider(height: 0.6, indent: 34),
        itemBuilder: (_, i) {
          if (i >= _articles.length) return _footer();
          final article = _articles[i];
          return RssArticleTile(
            article: article,
            onTap: () => _openArticle(article),
          );
        },
      ),
    );
  }

  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Icon(Icons.rss_feed, size: 36, color: scheme.outline),
          const SizedBox(height: 12),
          Center(
            child: Text(
              widget.sources.isEmpty ? '还没有订阅源' : '这里还没有文章',
              style: TextStyle(color: scheme.outline),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              widget.sources.isEmpty ? '先到「订阅源」tab 新增一个源' : '下拉刷新，让 core 去源站抓一次',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorState() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => _loadFirstPage(),
              child: const Text('重试'),
            ),
          ],
        ),
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
    if (!_hasMore && _articles.isNotEmpty) {
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
    return const SizedBox(height: 12);
  }
}
