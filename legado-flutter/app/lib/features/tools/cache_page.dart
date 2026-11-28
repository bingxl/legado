import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/book_cover.dart';
import 'tools_api.dart';
import 'tools_format.dart';

/// 缓存管理页（对应原版 `ui/main/bookshelf/cache/CacheActivity`）。
///
/// 列表与统计都来自 core 的 `Cache.*`，Dart 侧只负责「展示 + 确认后转发」；
/// 缓存任务的调度、失败重试、落盘全在 core 里，UI 不持有任务状态。
class CachePage extends StatefulWidget {
  const CachePage({super.key});

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  Map<String, dynamic> _stats = const {};
  List<Map<String, dynamic>> _books = const [];
  bool _loading = true;
  String? _error;

  /// 多选书籍：长按进入，批量清除/缓存/取消。
  final Set<int> _selected = <int>{};
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [silent] 用于下拉刷新与删除后的重拉：不清空已有列表，
  /// 避免屏幕闪一下白。
  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      // 两个请求都走同一份 core 快照，但分两次拿更适合分别兜错：
      // 统计挂了不该连带列表也看不到。
      final stats = await ToolsApi.cacheStats();
      final books = await ToolsApi.cacheBooks();
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _books = books;
        _loading = false;
        _error = null;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ── 多选 ────────────────────────────────────────────────

  void _enterSelect(int bookId) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(bookId);
    });
  }

  void _toggleSelect(int bookId) {
    setState(() {
      if (_selected.contains(bookId)) {
        _selected.remove(bookId);
      } else {
        _selected.add(bookId);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _books.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_books.map((book) => toolsInt(book['bookId'])));
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  /// 批量执行：单本失败不影响其余书，结束后统一汇报成功/失败数。
  Future<void> _batch(Future<void> Function(int bookId) op, String label) async {
    if (_selected.isEmpty) return;
    final ids = _selected.toList();
    var failed = 0;
    for (final id in ids) {
      try {
        await op(id);
      } on Object {
        failed++;
      }
    }
    _exitSelect();
    await _load(silent: true);
    if (!mounted) return;
    _toast(
      failed == 0
          ? '已$label ${ids.length} 本书'
          : '已$label ${ids.length - failed} 本，失败 $failed 本',
    );
  }

  Future<void> _batchAction(_BatchAction action) async {
    switch (action) {
      case _BatchAction.cache:
        await _batch(
          (id) => ToolsApi.cacheStart(id, 'missing'),
          '开始缓存',
        );
      case _BatchAction.recache:
        await _batch(
          (id) => ToolsApi.cacheStart(id, 'all'),
          '开始重新缓存',
        );
      case _BatchAction.cancel:
        await _batch(ToolsApi.cacheCancel, '取消');
      case _BatchAction.purge:
        final count = _selected.length;
        final ok = await _confirm(
          title: '清除所选缓存',
          message: '将删除所选 $count 本书的全部已缓存章节，确定继续？',
          okText: '清除 $count 本',
        );
        if (!ok) return;
        await _batch(ToolsApi.cachePurgeBook, '清除缓存');
    }
  }

  Future<void> _clearAll() async {
    final ok = await _confirm(
      title: '清空全部缓存',
      message: '将删除所有书籍的已缓存章节，缓存正文需要重新下载。确定继续？',
      okText: '全部清空',
    );
    if (!ok) return;
    await _run(() => ToolsApi.cacheClear(), '缓存已全部清空');
  }

  Future<void> _purge(Map<String, dynamic> book) async {
    final name = _bookName(book);
    final ok = await _confirm(
      title: '清除该书缓存',
      message: '将删除《$name》的全部已缓存章节，确定继续？',
      okText: '清除',
    );
    if (!ok) return;
    await _run(
      () => ToolsApi.cachePurgeBook(toolsInt(book['bookId'])),
      '已清除《$name》的缓存',
    );
  }

  /// 手动补缓存：自动缓存只覆盖读过的章与预取的窗口，
  /// 想整本离线就得点这里（对应原版 CacheActivity 的「缓存全书」）。
  Future<void> _cacheBook(Map<String, dynamic> book) async {
    final name = _bookName(book);
    await _run(
      () => ToolsApi.cacheStart(toolsInt(book['bookId']), 'missing'),
      '已开始缓存《$name》未缓存的章节',
    );
  }

  /// 全部重新缓存：已缓存的章也重抓一遍（`Cache.Start` 内部走 refresh，
  /// 不会命中旧缓存）。书源修了正文、或缓存里是防爬占位页时用这个。
  Future<void> _recacheBook(Map<String, dynamic> book) async {
    final name = _bookName(book);
    await _run(
      () => ToolsApi.cacheStart(toolsInt(book['bookId']), 'all'),
      '已开始重新缓存《$name》全部章节',
    );
  }

  Future<void> _cancel(Map<String, dynamic> book) async {
    final name = _bookName(book);
    await _run(
      () => ToolsApi.cacheCancel(toolsInt(book['bookId'])),
      '已取消《$name》的缓存任务',
    );
  }

  /// 统一的「调用 → 报结果 → 重拉」包装，省掉五处重复的 try/catch。
  Future<void> _run(Future<void> Function() action, String success) async {
    try {
      await action();
      if (!mounted) return;
      _toast(success);
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('操作失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('操作失败：$e');
    }
    if (!mounted) return;
    await _load(silent: true);
  }

  Future<void> _openChapters(Map<String, dynamic> book) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ChaptersSheet(
        bookId: toolsInt(book['bookId']),
        bookName: _bookName(book),
      ),
    );
    // 面板里可能删了单章，回来后统一重拉，不依赖返回值。
    if (!mounted) return;
    await _load(silent: true);
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    String okText = '确定',
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(okText),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  static String _bookName(Map<String, dynamic> book) {
    final name = toolsStr(book['name']).trim();
    return name.isEmpty ? '未命名' : name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                tooltip: '退出多选',
                icon: const Icon(Icons.close),
                onPressed: _exitSelect,
              )
            : null,
        title: Text(_selecting ? '已选 ${_selected.length} 项' : '缓存管理'),
        actions: _selecting
            ? [
                IconButton(
                  tooltip: _selected.length == _books.length ? '取消全选' : '全选',
                  icon: Icon(
                    _selected.length == _books.length
                        ? Icons.deselect_outlined
                        : Icons.select_all,
                  ),
                  onPressed: _toggleSelectAll,
                ),
                PopupMenuButton<_BatchAction>(
                  tooltip: '批量操作',
                  onSelected: _batchAction,
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _BatchAction.cache,
                      child: Text('缓存未缓存章节'),
                    ),
                    PopupMenuItem(
                      value: _BatchAction.recache,
                      child: Text('全部重新缓存'),
                    ),
                    PopupMenuItem(
                      value: _BatchAction.cancel,
                      child: Text('取消任务'),
                    ),
                    PopupMenuItem(
                      value: _BatchAction.purge,
                      child: Text('清除所选缓存'),
                    ),
                  ],
                ),
              ]
            : [
                IconButton(
                  tooltip: '全部清空',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  // 空列表时禁用：没有缓存还允许点，只会给一个无意义的确认框。
                  onPressed: _books.isEmpty ? null : _clearAll,
                ),
                IconButton(
                  tooltip: '刷新',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => _load(silent: true),
                ),
              ],
      ),
      body: Column(
        children: [
          if (!_loading && _error == null) _statsBar(),
          const Divider(height: 0.6),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _statsBar() {
    final books = toolsInt(_stats['books']);
    final chapters = toolsInt(_stats['chapters']);
    final size = toolsInt(_stats['size']);
    final running = toolsInt(_stats['running']);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        children: [
          _StatCell(value: '$books', label: '本书'),
          _StatCell(value: '$chapters', label: '章'),
          _StatCell(value: formatBytes(size), label: '占用'),
          if (running > 0) _StatCell(value: '$running', label: '任务中'),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _errorState(_error!);
    if (_books.isEmpty) return _emptyState();
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _books.length,
        itemBuilder: (_, i) => _bookRow(_books[i]),
      ),
    );
  }

  Widget _bookRow(Map<String, dynamic> book) {
    final scheme = Theme.of(context).colorScheme;
    final bookId = toolsInt(book['bookId']);
    final name = _bookName(book);
    final total = toolsInt(book['totalChapters']);
    final cached = toolsInt(book['cachedChapters']);
    final size = toolsInt(book['size']);
    final job = _jobOf(book);
    final running = job != null && toolsStr(job['state']) == 'running';
    final checked = _selected.contains(bookId);

    return InkWell(
      // 长按进入多选；已在多选里再长按等同于勾选，和点击行为一致。
      onLongPress: () => _selecting ? _toggleSelect(bookId) : _enterSelect(bookId),
      onTap: _selecting
          ? () => _toggleSelect(bookId)
          : () => _openChapters(book),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_selecting) ...[
              Checkbox(
                value: checked,
                onChanged: (_) => _toggleSelect(bookId),
              ),
              const SizedBox(width: 4),
            ],
            _Cover(book: book),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(
                    '已缓存 $cached/$total 章 · ${formatBytes(size)}',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                  if (job != null && running) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: cacheProgress(
                        toolsInt(job['done']),
                        toolsInt(job['failed']),
                        toolsInt(job['total']),
                      ),
                      minHeight: 3,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '缓存中 ${cacheProgressLabel(toolsInt(job['done']), toolsInt(job['failed']), toolsInt(job['total']))}'
                      '${_jobMessage(job)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  ],
                ],
              ),
            ),
            // 多选时收起单本菜单，避免两种操作模式混在一起。
            if (!_selecting)
              PopupMenuButton<_BookAction>(
                tooltip: '更多',
                onSelected: (action) {
                  switch (action) {
                    case _BookAction.cache:
                      _cacheBook(book);
                    case _BookAction.recache:
                      _recacheBook(book);
                    case _BookAction.chapters:
                      _openChapters(book);
                    case _BookAction.purge:
                      _purge(book);
                    case _BookAction.cancel:
                      _cancel(book);
                  }
                },
                itemBuilder: (_) => [
                  if (!running)
                    const PopupMenuItem(
                      value: _BookAction.cache,
                      child: Text('缓存未缓存章节'),
                    ),
                  if (!running)
                    const PopupMenuItem(
                      value: _BookAction.recache,
                      child: Text('全部重新缓存'),
                    ),
                  const PopupMenuItem(
                    value: _BookAction.chapters,
                    child: Text('查看已缓存章节'),
                  ),
                  if (running)
                    const PopupMenuItem(
                      value: _BookAction.cancel,
                      child: Text('取消任务'),
                    ),
                  const PopupMenuItem(
                    value: _BookAction.purge,
                    child: Text('清除该书缓存'),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 任务提示语：core 的 message 是「当前章节标题或最近一条错误」，
  /// 有就接在进度后面，没有只显示进度。
  static String _jobMessage(Map<String, dynamic>? job) {
    if (job == null) return '';
    final message = toolsStr(job['message']).trim();
    return message.isEmpty ? '' : ' · $message';
  }

  static Map<String, dynamic>? _jobOf(Map<String, dynamic> book) {
    final job = book['job'];
    if (job is Map) return job.cast<String, dynamic>();
    return null;
  }

  Widget _errorState(String message) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          const SizedBox(height: 120),
          Icon(Icons.sd_storage_outlined, size: 36, color: scheme.outline),
          const SizedBox(height: 12),
          Center(
            child: Text('还没有缓存的书', style: TextStyle(color: scheme.outline)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '在阅读器里缓存章节后，这里可以看到占用与任务进度；长按书项可多选批量操作',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

enum _BookAction { cache, recache, chapters, purge, cancel }

/// 多选后的批量操作（与单本菜单分开，避免两种模式混用）。
enum _BatchAction { cache, recache, cancel, purge }

class _StatCell extends StatelessWidget {
  const _StatCell({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11, color: scheme.outline)),
        ],
      ),
    );
  }
}

/// 封面：网络图 + 首字兜底。
class _Cover extends StatelessWidget {
  const _Cover({required this.book});

  final Map<String, dynamic> book;

  @override
  Widget build(BuildContext context) {
    return BookCover(
      name: toolsStr(book['name']).trim(),
      url: '${book['cover'] ?? ''}',
      width: 40,
      height: 52,
      radius: 6,
      fontSize: 16,
    );
  }
}

/// 已缓存章节面板。
///
/// 单独做成 StatefulWidget：章节数可能几百条，删除单章后只需要
/// 重拉面板内的列表，不必让整个缓存页重建。
class _ChaptersSheet extends StatefulWidget {
  const _ChaptersSheet({required this.bookId, required this.bookName});

  final int bookId;
  final String bookName;

  @override
  State<_ChaptersSheet> createState() => _ChaptersSheetState();
}

class _ChaptersSheetState extends State<_ChaptersSheet> {
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  /// 多选章节：长按条目进入，批量删除。
  final Set<int> _selected = <int>{};
  bool _selecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ToolsApi.cacheChapters(widget.bookId);
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _enterSelect(int index) {
    setState(() {
      _selecting = true;
      _selected
        ..clear()
        ..add(index);
    });
  }

  void _toggleSelect(int index) {
    setState(() {
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        _selected.add(index);
      }
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selected.length == _items.length) {
        _selected.clear();
      } else {
        _selected.addAll(_items.map((item) => toolsInt(item['index'])));
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _delete(Map<String, dynamic> chapter) async {
    final index = toolsInt(chapter['index']);
    try {
      await ToolsApi.cacheDelete(widget.bookId, [index]);
      if (!mounted) return;
      _toast('已删除第 ${index + 1} 章缓存');
      await _load();
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('删除失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败：$e');
    }
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除所选缓存'),
        content: Text('将删除所选 $count 章缓存，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final indexes = _selected.toList();
    try {
      await ToolsApi.cacheDelete(widget.bookId, indexes);
      if (!mounted) return;
      _exitSelect();
      _toast('已删除 $count 章缓存');
      await _load();
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('删除失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败：$e');
    }
  }

  // 面板是 modal，ScaffoldMessenger 会挂在页面根部，提示仍可见。
  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.65,
        child: Column(
          children: [
            ListTile(
              title: Text(
                widget.bookName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                _selecting
                    ? '已选 ${_selected.length} 章'
                    : (_loading ? '正在读取…' : '已缓存 ${_items.length} 章 · 长按可多选'),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              trailing: _items.isEmpty
                  ? null
                  : TextButton(
                      onPressed: _selecting ? _exitSelect : () => _enterSelect(
                        toolsInt(_items.first['index']),
                      ),
                      child: Text(_selecting ? '退出' : '多选'),
                    ),
            ),
            const Divider(height: 0.6),
            Expanded(child: _body()),
            if (_selecting) _batchBar(),
          ],
        ),
      ),
    );
  }

  Widget _batchBar() {
    return Container(
      decoration: BoxDecoration(
        border: Border(top: Divider.createBorderSide(context)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text('已选 ${_selected.length} 章'),
          const Spacer(),
          TextButton(
            onPressed: _toggleSelectAll,
            child: Text(
              _selected.length == _items.length ? '取消全选' : '全选',
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _selected.isEmpty ? null : _deleteSelected,
            child: const Text('删除选中'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('这本书还没有缓存章节', style: TextStyle(color: scheme.outline)),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 0.6, indent: 16),
      itemBuilder: (_, i) {
        final chapter = _items[i];
        final index = toolsInt(chapter['index']);
        final time = parseTime(chapter['updatedAt']);
        return ListTile(
          dense: true,
          selected: _selected.contains(index),
          leading: _selecting
              ? Checkbox(
                  value: _selected.contains(index),
                  onChanged: (_) => _toggleSelect(index),
                )
              : null,
          onLongPress: () =>
              _selecting ? _toggleSelect(index) : _enterSelect(index),
          // 非多选时点击不删：删除只走右侧图标，避免误触丢缓存。
          onTap: _selecting ? () => _toggleSelect(index) : null,
          title: Text(
            toolsStr(chapter['title']),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              formatBytes(toolsInt(chapter['size'])),
              if (time != null) formatDateTime(time),
            ].join(' · '),
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          trailing: _selecting
              ? null
              : IconButton(
                  tooltip: '删除本章缓存',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => _delete(chapter),
                ),
        );
      },
    );
  }
}
