import 'package:flutter/material.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/shelf_events.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/router/routes.dart';
import '../../core/widgets/book_cover.dart';
import '../../core/widgets/copy_links.dart';
import '../reader/widgets/toc_sheet_scaffold.dart';
import '../shelf/shelf_api.dart';
import 'book_edit_dialogs.dart';
import 'chapter_preview.dart';

/// 书籍详情页（对应原版 `ui/book/info/BookInfoActivity`）。
///
/// 入口来自发现/搜索：点开结果时 core 已用 `Source.PreviewBook` 把书入库
/// （试读态，不进书架），所以这里只需要 bookId。
///
/// 命名路由参数：`{'bookId': int, 'bookName': String?}`。
class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.bookId, this.bookName});

  final int bookId;

  /// 详情还没加载出来时的标题兜底（搜索结果里的书名）。
  final String? bookName;

  /// 供壳层接入 `/book` 路由时统一解析参数。
  static Widget fromRouteArguments(Object? arguments) {
    final args = arguments is Map ? arguments : const {};
    return BookDetailPage(
      bookId: (args['bookId'] as num?)?.toInt() ?? 0,
      bookName: args['bookName'] as String?,
    );
  }

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _chapters = const [];

  bool _loading = true;
  bool _adding = false;
  bool _refreshing = false;
  bool _introExpanded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.bookId <= 0) {
      setState(() {
        _error = '缺少书籍 ID';
        _loading = false;
      });
      return;
    }
    setState(() {
      _error = null;
      if (_detail == null) _loading = true;
    });
    final client = LegadoClient.instance;
    try {
      final detail = await client.call(Api.shelfGetBook, [widget.bookId]);
      if (!mounted) return;
      if (detail is! Map<String, dynamic>) {
        setState(() {
          _error = '书籍详情格式不正确';
          _loading = false;
        });
        return;
      }
      List<Map<String, dynamic>> chapters;
      try {
        chapters = await client.callList(Api.readerGetChapters, [
          widget.bookId,
        ]);
      } on LegadoError catch (e) {
        if (!mounted) return;
        // 目录失败不影响详情：阅读器打开时还会再拉一次目录。
        setState(() {
          _detail = detail;
          _chapters = const [];
          _loading = false;
        });
        _toast('目录加载失败：${e.message}');
        return;
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _chapters = chapters;
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

  /// 详情页刷新：对齐原版 `BookInfoActivity.refreshBook` —— 重抓详情 + 目录，
  /// 不是只读本地库（早期实现把菜单「刷新」和下拉都接到了 [_load]，
  /// 表现为刷新后目录/简介永远不变）。
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final result = await ShelfApi.refreshBook(widget.bookId);
      if (!mounted) return;
      final added = (result['added'] as num?)?.toInt() ?? 0;
      // 章数/最新章节可能变了，书架列表要跟着更新。
      ShelfEvents.changed();
      _toast(added > 0 ? '已刷新，新增 $added 章' : '已刷新');
      await _load();
    } on LegadoError catch (e) {
      if (!mounted) return;
      // 本地书不支持网络刷新：不打断页面，重新回读本地目录即可。
      if (e.code == 'INVALID_ARGUMENT' && e.message.contains('本地书')) {
        await _load();
        return;
      }
      _toast('刷新失败：${e.message}');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// 试读转正：书已在库（含目录），只需把书架标记打开。
  Future<void> _putOnShelf() async {
    if (_adding) return;
    setState(() => _adding = true);
    try {
      await LegadoClient.instance.call(Api.shelfPutOnShelf, [widget.bookId]);
      // 书架页常驻在 IndexedStack 里，不广播它就不会重新拉列表。
      ShelfEvents.changed();
      if (!mounted) return;
      _toast('已加入书架');
      await _load();
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('加入书架失败：${e.message}');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  /// 移出书架：对齐原版 `BookInfoActivity.deleteBook` ——
  /// 先确认（原版 `bookInfoDeleteAlert` 默认开），再走 `Shelf.DeleteBook`
  /// （删书 + 清目录/进度/缓存），成功后返回上一页（原版 `finish()`）。
  Future<void> _removeFromShelf() async {
    if (_adding) return;
    final name = _title;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('是否确认删除？'),
        content: Text('将从书架移除《$name》，并清空它的目录、阅读进度与缓存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _adding = true);
    try {
      await LegadoClient.instance.call(Api.shelfDeleteBook, [widget.bookId]);
      ShelfEvents.changed();
      if (!mounted) return;
      _toast('已移出书架');
      Navigator.of(context).pop(true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('移出书架失败：${e.message}');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openReader([int? chapterIndex]) {
    final arguments = <String, Object?>{
      'bookId': widget.bookId,
      'bookName': _title,
    };
    if (chapterIndex != null) arguments['chapterIndex'] = chapterIndex;
    // 本地漫画（bookUrl 是文件路径）走漫画阅读器；网络漫画走文字阅读器 images。
    final bookUrl = '${_detail?['bookUrl'] ?? ''}';
    final isLocalFile =
        bookUrl.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(bookUrl);
    if ('${_detail?['format'] ?? ''}' == 'comic' && isLocalFile) {
      arguments['localComic'] = true;
    }
    Navigator.pushNamed(context, RouteNames.reader, arguments: arguments);
  }

  String get _title {
    final name = '${_detail?['name'] ?? widget.bookName ?? ''}'.trim();
    return name.isEmpty ? '书籍详情' : name;
  }

  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  /// 编辑书名/作者/封面/简介/分组。
  Future<void> _editBook() async {
    final detail = _detail;
    if (detail == null) return;
    final saved = await showBookEditDialog(context, detail);
    if (saved == true) {
      ShelfEvents.changed();
      _toast('已保存');
      await _load();
    }
  }

  /// 换源：全源搜索同名书 → 选中 → core 重建目录并迁移进度。
  ///
  /// 换源后 `bookUrl` 变了，书的 rowid 也会变（实现是删旧插新），
  /// 所以成功后必须用返回的新 id 替换当前路由，否则详情页还指着旧书。
  Future<void> _changeSource() async {
    final detail = _detail;
    if (detail == null) return;
    final picked = await showChangeSourceDialog(context, detail);
    if (picked == null) return;
    final bookUrl = '${picked['bookUrl'] ?? ''}';
    if (bookUrl.isEmpty) {
      _toast('该搜索结果没有书籍地址');
      return;
    }
    _toast('正在换源…');
    try {
      final result = await ShelfApi.changeSource(
        bookId: widget.bookId,
        sourceId: 0,
        bookUrl: bookUrl,
      );
      if (!mounted) return;
      final newId = (result['bookId'] as num?)?.toInt() ?? widget.bookId;
      // 换源会重建目录、改写书源，书架上的封面/最新章节都会变。
      ShelfEvents.changed();
      if (newId != widget.bookId) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => BookDetailPage(
              bookId: newId,
              bookName: '${result['book']?['name'] ?? picked['name'] ?? ''}',
            ),
          ),
        );
      } else {
        _toast('已换源');
        await _load();
      }
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('换源失败：${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail ?? const <String, dynamic>{};
    // 复制项随详情变化：本地书没有书源地址、无封面时没有封面地址。
    final links = bookCopyLinks(
      bookUrl: '${detail['bookUrl'] ?? ''}',
      origin: '${detail['origin'] ?? ''}',
      coverUrl: '${detail['cover'] ?? ''}',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '换源',
            icon: const Icon(Icons.swap_horiz),
            onPressed: _bodyReady ? _changeSource : null,
          ),
          IconButton(
            tooltip: '编辑信息',
            icon: const Icon(Icons.edit_outlined),
            onPressed: _bodyReady ? _editBook : null,
          ),
          PopupMenuButton<int>(
            tooltip: '更多',
            // -1 是刷新；非负数是 links 的下标。
            onSelected: (value) {
              if (value < 0) {
                _refresh();
                return;
              }
              copyLink(context, links[value], notify: _toast);
            },
            itemBuilder: (_) => [
              const PopupMenuItem<int>(
                value: -1,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.refresh, size: 20),
                  title: Text('刷新'),
                ),
              ),
              if (links.isNotEmpty) const PopupMenuDivider(),
              for (var i = 0; i < links.length; i++)
                PopupMenuItem<int>(
                  value: i,
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.link, size: 20),
                    title: Text('复制${links[i].label}'),
                    subtitle: Text(
                      links[i].value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _body(),
    );
  }

  /// 详情还没加载出来时，换源/编辑没有可用的字段与 id。
  bool get _bodyReady => _detail != null;

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null && _detail == null) {
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
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }

    final detail = _detail ?? const <String, dynamic>{};
    return RefreshIndicator(
      onRefresh: _refresh,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              _header(detail),
              const SizedBox(height: 16),
              _actions(detail),
              const SizedBox(height: 24),
              _intro(detail),
              const SizedBox(height: 24),
              _chapterSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(Map<String, dynamic> detail) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = '${detail['name'] ?? widget.bookName ?? ''}';
    final author = '${detail['author'] ?? ''}';
    final kind = '${detail['kind'] ?? ''}';
    final formatLabel = '${detail['formatLabel'] ?? ''}';
    final percent = (detail['percent'] as num?)?.toInt() ?? 0;
    final total = _chapterCount(detail);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BookCover(
          name: name,
          url: '${detail['cover'] ?? ''}',
          width: 96,
          height: 132,
          radius: 8,
          fontSize: 36,
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name.isEmpty ? '未知书名' : name,
                style: theme.textTheme.titleLarge,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Text(
                author.isEmpty ? '佚名' : author,
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (kind.isNotEmpty) _Tag(kind),
                  if (formatLabel.isNotEmpty) _Tag(formatLabel),
                  _Tag('$total 章'),
                  if (percent > 0) _Tag('已读 $percent%'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actions(Map<String, dynamic> detail) {
    final inShelf = detail['inShelf'] == true;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => _openReader(),
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('开始阅读'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: inShelf
              ? OutlinedButton.icon(
                  onPressed: _adding ? null : _removeFromShelf,
                  icon: _adding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline, size: 18),
                  label: Text(_adding ? '处理中…' : '移出书架'),
                )
              : OutlinedButton.icon(
                  onPressed: _adding ? null : _putOnShelf,
                  icon: _adding
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.library_add_outlined, size: 18),
                  label: Text(_adding ? '加入中…' : '加入书架'),
                ),
        ),
      ],
    );
  }

  Widget _intro(Map<String, dynamic> detail) {
    final intro = '${detail['intro'] ?? ''}'.trim();
    final scheme = Theme.of(context).colorScheme;
    final canExpand = intro.length > 180;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('简介', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(
          intro.isEmpty ? '暂无简介' : intro,
          style: TextStyle(
            fontSize: 13,
            height: 1.6,
            color: scheme.onSurfaceVariant,
          ),
          maxLines: _introExpanded ? null : 6,
          overflow: _introExpanded ? null : TextOverflow.ellipsis,
        ),
        if (canExpand)
          TextButton(
            onPressed: () => setState(() => _introExpanded = !_introExpanded),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(_introExpanded ? '收起' : '展开'),
          ),
      ],
    );
  }

  int _chapterCount(Map<String, dynamic> detail) {
    if (_chapters.isNotEmpty) return _chapters.length;
    return (detail['totalChapters'] as num?)?.toInt() ?? 0;
  }

  Widget _chapterSection() {
    final theme = Theme.of(context);
    final preview = previewChapters(_chapters);
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('目录（${_chapters.length}）', style: theme.textTheme.titleMedium),
            const Spacer(),
            TextButton(
              onPressed: _chapters.isEmpty ? null : _showAllChapters,
              child: const Text('全部章节'),
            ),
          ],
        ),
        if (_chapters.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '目录还没抓取，进入阅读时会自动更新',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
          )
        else ...[
          for (final chapter in preview) _chapterRow(chapter),
          if (_chapters.length > preview.length)
            Align(
              alignment: Alignment.center,
              child: TextButton(
                onPressed: _showAllChapters,
                child: Text('查看全部 ${_chapters.length} 章'),
              ),
            ),
        ],
      ],
    );
  }

  Widget _chapterRow(Map<String, dynamic> chapter) {
    final title = '${chapter['title'] ?? ''}';
    final index = (chapter['index'] as num?)?.toInt() ?? 0;
    final scheme = Theme.of(context).colorScheme;

    if (chapter['isVolume'] == true) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      );
    }
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _openReader(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5),
              ),
            ),
            // 付费 / VIP 标记：来自书源 chapterList 的 isPay / isVip。
            if (chapter['isPay'] == true)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.shopping_cart_outlined,
                  size: 13,
                  color: scheme.error,
                ),
              )
            else if (chapter['isVip'] == true)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.lock_outline,
                  size: 13,
                  color: scheme.outline,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 完整目录弹层：与阅读器目录共用 [TocSheetScaffold]，
  /// 自带「回到开头 / 跳到最新」，上千章时 ListView.builder 只构建可见部分。
  void _showAllChapters() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => TocSheetScaffold(
        title: '全部章节',
        countLabel: '共 ${_chapters.length} 章',
        itemCount: _chapters.length,
        itemBuilder: (_, i) => _chapterRow(_chapters[i]),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: scheme.onSecondaryContainer),
      ),
    );
  }
}
