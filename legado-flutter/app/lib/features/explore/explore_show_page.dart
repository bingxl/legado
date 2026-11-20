import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';
import '../../core/widgets/book_cover.dart';
import 'explore_api.dart';
import 'explore_results.dart';

/// 发现分类详情页（对应原版 `ui/book/explore/ExploreShowActivity`）。
///
/// 标题是分类名，主体是一列书（对应原版 item_search.xml）：
/// 封面 + 书名 + 作者 + 类型标签 + 最新章节 + 简介，条目间有分隔线；
/// 滚到底自动翻页，页脚显示加载中 / 没有更多。
class ExploreShowPage extends StatefulWidget {
  const ExploreShowPage({
    super.key,
    required this.sourceId,
    required this.kindTitle,
    required this.kindUrl,
  });

  final int sourceId;
  final String kindTitle;
  final String kindUrl;

  /// 从路由参数构造。
  factory ExploreShowPage.fromRouteArguments(Object? args) {
    final map = args is Map ? args : const {};
    return ExploreShowPage(
      sourceId: (map['sourceId'] as num?)?.toInt() ?? 0,
      kindTitle: (map['kindTitle'] as String?) ?? '发现',
      kindUrl: (map['kindUrl'] as String?) ?? '',
    );
  }

  @override
  State<ExploreShowPage> createState() => _ExploreShowPageState();
}

class _ExploreShowPageState extends State<ExploreShowPage> {
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _books = const [];

  int _page = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  /// 正在打开的书（bookUrl）。
  String? _openingUrl;

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

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 320) _loadMore();
  }

  Future<void> _loadFirstPage() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ExploreApi.explore(widget.sourceId, widget.kindUrl, 1);
      if (!mounted) return;
      setState(() {
        _books = mergeResults(const [], data);
        _page = 1;
        _hasMore = data.isNotEmpty;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || _error != null) return;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await ExploreApi.explore(
        widget.sourceId,
        widget.kindUrl,
        next,
      );
      if (!mounted) return;
      setState(() {
        _books = mergeResults(_books, data);
        _page = next;
        // 空页即到底：书源没有明确的「总页数」可问。
        _hasMore = data.isNotEmpty;
        _loadingMore = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      _toast('加载下一页失败：${e.message}');
    }
  }

  /// 打开书籍：先 PreviewBook 入库拿到 bookId（试读态），再进详情页。
  Future<void> _openBook(Map<String, dynamic> item) async {
    if (_openingUrl != null) return;
    final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
    if (bookUrl.isEmpty) {
      _toast('这条结果没有书籍链接，无法打开');
      return;
    }
    setState(() => _openingUrl = bookUrl);
    try {
      final brief = await LegadoClient.instance.call('Source.PreviewBook', [
        widget.sourceId,
        bookUrl,
        '${item['name'] ?? ''}',
        '${item['author'] ?? ''}',
        '${item['variable'] ?? ''}',
        '${item['cover'] ?? ''}',
      ]);
      if (!mounted) return;
      final map = brief is Map<String, dynamic>
          ? brief
          : const <String, dynamic>{};
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.kindTitle)),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return _emptyState(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        actionLabel: '重试',
        onAction: _loadFirstPage,
      );
    }

    if (_books.isEmpty) {
      return _emptyState(
        icon: Icons.menu_book_outlined,
        message: '这个分类下没有书',
        actionLabel: '刷新',
        onAction: _loadFirstPage,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadFirstPage,
      child: ListView.separated(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _books.length + 1,
        separatorBuilder: (_, _) => const Divider(height: 0.6),
        itemBuilder: (ctx, i) {
          if (i == _books.length) return _footer();
          return _bookTile(_books[i]);
        },
      ),
    );
  }

  /// 书条目（对应原版 item_search.xml）。
  Widget _bookTile(Map<String, dynamic> book) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${book['name'] ?? ''}';
    final author = '${book['author'] ?? ''}';
    final intro = '${book['intro'] ?? ''}'.trim();
    final lastChapter = '${book['lastChapter'] ?? ''}'.trim();
    final kind = '${book['kind'] ?? ''}'.trim();
    final opening =
        _openingUrl != null && _openingUrl == '${book['bookUrl'] ?? ''}';

    return InkWell(
      onTap: opening ? null : () => _openBook(book),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 80,
              height: 110,
              child: BookCover(
                name: name,
                url: '${book['cover'] ?? ''}',
                width: 80,
                height: 110,
                radius: 4,
                fontSize: 24,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (opening)
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    author.isEmpty ? '作者：' : '作者：$author',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (kind.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final label in kind.split(','))
                          if (label.trim().isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.secondaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                label.trim(),
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                      ],
                    ),
                  ],
                  if (lastChapter.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '最新：$lastChapter',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                  if (intro.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      intro,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.outline),
                    ),
                  ],
                ],
              ),
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
    return const SizedBox(height: 24);
  }

  Widget _emptyState({
    required IconData icon,
    required String message,
    required String actionLabel,
    VoidCallback? onAction,
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
