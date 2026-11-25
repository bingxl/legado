import 'package:flutter/material.dart';

import 'dart:math' as math;

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/book_cover.dart';
import '../source/source_api.dart';
import 'shelf_api.dart';

/// 书架管理（对应原版 `BookshelfManageActivity`）。
///
/// 原版进入页面即处于多选模式，支持拖拽连选、搜索过滤、批量移动/加入分组、
/// 开关更新、换源、清缓存与删除。这里全部对齐：长按后拖过书本即区间连选，
/// 底部批量条包含换源与清缓存。
class ShelfManagePage extends StatefulWidget {
  const ShelfManagePage({super.key, this.groupId = 0});

  /// 0 表示全部（与书架的「全部」chip 一致）。
  final int groupId;

  static ShelfManagePage fromRouteArguments(Object? args) {
    final map = args is Map ? args : const <String, Object?>{};
    return ShelfManagePage(groupId: (map['groupId'] as num?)?.toInt() ?? 0);
  }

  @override
  State<ShelfManagePage> createState() => _ShelfManagePageState();
}

class _ShelfManagePageState extends State<ShelfManagePage> {
  List<Map<String, dynamic>> _books = const [];
  List<Map<String, dynamic>> _groups = const [];
  final Set<int> _selected = <int>{};
  final TextEditingController _keyword = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<GlobalKey> _rowKeys = <GlobalKey>[];

  /// 长按起点与拖拽过程中的区间预览。松手才把区间并入 [_selected]，
  /// 中途重拖不会留下脏选择。
  int? _rangeAnchor;
  Set<int> _rangePreview = <int>{};

  bool _loading = true;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keyword.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = LegadoClient.instance;
      final groups = await client.callList(Api.shelfListGroups);
      final books = await client.callList(Api.shelfListBooks, [widget.groupId]);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _books = books;
        _selected.removeWhere((id) => !books.any((b) => b['id'] == id));
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

  List<Map<String, dynamic>> get _visibleBooks {
    final key = _keyword.text.trim().toLowerCase();
    if (key.isEmpty) return _books;
    return _books.where((b) {
      final name = '${b['name'] ?? ''}'.toLowerCase();
      final author = '${b['author'] ?? ''}'.toLowerCase();
      return name.contains(key) || author.contains(key);
    }).toList();
  }

  // 批量操作需要多条提示排队，不隐藏上一条。
  void _toast(String message) =>
      showAppToast(context, message, mounted: mounted, replace: false);

  /// 批量操作统一入口：防重入 + 失败只提示，不清选择（便于重试）。
  Future<void> _run(String label, Future<void> Function(List<int> ids) action) async {
    if (_busy || _selected.isEmpty) return;
    final ids = List<int>.from(_selected);
    setState(() => _busy = true);
    try {
      await action(ids);
      if (!mounted) return;
      _toast('$label ${ids.length} 本成功');
      _selected.clear();
      await _load();
    } on LegadoError catch (e) {
      _toast('$label 失败：${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<int?> _pickGroup({required bool asMembership}) async {
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(asMembership ? '加入分组' : '移动到分组'),
        content: SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!asMembership)
                  ListTile(
                    title: const Text('未分组'),
                    onTap: () => Navigator.pop(ctx, 0),
                  ),
                for (final group in _groups)
                  ListTile(
                    title: Text('${group['name'] ?? ''}'),
                    subtitle: Text(group['show'] == false ? '（已隐藏）' : ''),
                    onTap: () => Navigator.pop(
                      ctx,
                      (group['id'] as num?)?.toInt() ?? 0,
                    ),
                  ),
                if (_groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('还没有分组，请先在分组管理里新建'),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    return picked;
  }

  Future<void> _deleteSelected() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定从书架移除选中的 ${_selected.length} 本书吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run('已移除', ShelfApi.deleteBooks);
  }

  /// 找到手指/鼠标当前落在哪一本书上。长按事件只发给起点那一行，
  /// 所以这里按每行的 GlobalKey 做命中测试，而不是依赖事件路由。
  int? _rowIndexAt(Offset global) {
    for (var i = 0; i < _rowKeys.length; i++) {
      final box = _rowKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return i;
    }
    return null;
  }

  Future<int?> _pickSource() async {
    List<Map<String, dynamic>> sources;
    try {
      sources = await SourceApi.list();
    } on LegadoError catch (e) {
      _toast('读取书源失败: ${e.message}');
      return null;
    }
    if (!mounted) return null;
    final usable = sources.where((s) => s['enabled'] != false).toList();
    if (usable.isEmpty) {
      _toast('还没有启用的书源');
      return null;
    }
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量换源'),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    '逐本在所选书源里按书名+作者精确搜索，找不到就跳过；换源后进度按章序迁移。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                for (final source in usable)
                  ListTile(
                    dense: true,
                    title: Text('${source['name'] ?? source['bookSourceName'] ?? ''}'),
                    subtitle: Text('${source['url'] ?? source['bookSourceUrl'] ?? ''}'),
                    onTap: () => Navigator.pop(
                      ctx,
                      (source['id'] as num?)?.toInt() ?? 0,
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _batchChangeSource() async {
    final sourceId = await _pickSource();
    if (sourceId == null || sourceId <= 0 || !mounted) return;
    final ids = List<int>.from(_selected);
    setState(() => _busy = true);
    try {
      final result = await ShelfApi.batchChangeSource(ids, sourceId);
      if (!mounted) return;
      final errors = (result['errors'] as List?) ?? const [];
      _toast(
        '换源完成：成功 ${result['succeeded'] ?? 0}，跳过 ${result['skipped'] ?? 0}，'
        '失败 ${result['failed'] ?? 0}'
        '${errors.isEmpty ? '' : '；${errors.first}'}',
      );
      _selected.clear();
      await _load();
    } on LegadoError catch (e) {
      _toast('换源失败: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清理缓存'),
        content: Text('确定清理选中 ${_selected.length} 本书的正文与图片缓存吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清理'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = List<int>.from(_selected);
    setState(() => _busy = true);
    var done = 0;
    var failed = 0;
    for (final id in ids) {
      try {
        await ShelfApi.purgeBookCache(id);
        done++;
      } on Object {
        failed++;
      }
    }
    if (!mounted) return;
    _toast('已清理 $done 本缓存${failed > 0 ? '，$failed 本失败' : ''}');
    _selected.clear();
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleBooks;
    // 行数变化时同步命中测试用的 key，避免长按拖到筛选后的空位。
    while (_rowKeys.length < visible.length) {
      _rowKeys.add(GlobalKey());
    }
    if (_rowKeys.length > visible.length) {
      _rowKeys.length = visible.length;
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _keyword,
              decoration: InputDecoration(
                hintText: '筛选书名 / 作者',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _keyword.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _keyword.clear()),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
            child: Text(
              '长按一本书并拖动可连续选择',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _selected.addAll(visible.map(
                    (b) => (b['id'] as num?)?.toInt() ?? 0,
                  ));
                }),
                child: const Text('全选'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  final ids = visible
                      .map((b) => (b['id'] as num?)?.toInt() ?? 0)
                      .toSet();
                  _selected.removeWhere(ids.contains);
                }),
                child: const Text('取消选中'),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('已选 ${_selected.length} 本'),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              FilledButton(
                                onPressed: _load,
                                child: const Text('重试'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : ListView.separated(
                        controller: _scroll,
                        itemCount: visible.length,
                        separatorBuilder: (_, _) => const Divider(height: 0.6),
                        itemBuilder: (_, i) => _bookRow(visible[i], i),
                      ),
          ),
          _bottomBar(),
        ],
      ),
    );
  }

  Widget _bookRow(Map<String, dynamic> book, int index) {
    final id = (book['id'] as num?)?.toInt() ?? 0;
    final selected = _selected.contains(id);
    final inRange = _rangePreview.contains(id);
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) {
        _rangeAnchor = index;
        _rangePreview = {id};
        setState(() {});
      },
      onLongPressMoveUpdate: (details) {
        final anchor = _rangeAnchor;
        if (anchor == null) return;
        // 拖到上下边缘时跟着滚动，才能连选到屏幕外的书。
        final screen = MediaQuery.sizeOf(context).height;
        if (_scroll.hasClients) {
          final dy = details.globalPosition.dy;
          if (dy < 88) {
            _scroll.jumpTo(
              (_scroll.offset - 14).clamp(0.0, _scroll.position.maxScrollExtent),
            );
          } else if (dy > screen - 88) {
            _scroll.jumpTo(
              (_scroll.offset + 14).clamp(0.0, _scroll.position.maxScrollExtent),
            );
          }
        }
        final target = _rowIndexAt(details.globalPosition);
        if (target == null) return;
        final lo = math.min(anchor, target);
        final hi = math.max(anchor, target);
        final range = _visibleBooks
            .sublist(lo, hi + 1)
            .map((b) => (b['id'] as num?)?.toInt() ?? 0)
            .toSet();
        if (range.length != _rangePreview.length ||
            !range.containsAll(_rangePreview)) {
          setState(() => _rangePreview = range);
        }
      },
      onLongPressEnd: (_) {
        if (_rangeAnchor != null) _selected.addAll(_rangePreview);
        _rangeAnchor = null;
        _rangePreview = <int>{};
        setState(() {});
      },
      onLongPressCancel: () {
        _rangeAnchor = null;
        _rangePreview = <int>{};
        setState(() {});
      },
      child: Container(
        key: _rowKeys[index],
        color: inRange
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : selected
                ? scheme.primaryContainer.withValues(alpha: 0.25)
                : null,
        child: ListTile(
          dense: true,
          leading: Checkbox(
            value: selected || inRange,
            onChanged: (v) => setState(() {
              if (v == true) {
                _selected.add(id);
              } else {
                _selected.remove(id);
              }
            }),
          ),
          title: Row(
            children: [
              _Cover(book: book, size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${book['name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          subtitle: Text(
            '${book['author'] ?? ''}${book['canUpdate'] == false ? ' · 已暂停更新' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => setState(() {
            if (selected) {
              _selected.remove(id);
            } else {
              _selected.add(id);
            }
          }),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
          ),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              _action(Icons.move_down, '移动分组', () async {
                final groupId = await _pickGroup(asMembership: false);
                if (groupId != null) {
                  await _run('已移动', (ids) => ShelfApi.moveToGroups(ids, groupId));
                }
              }),
              _action(Icons.group_add_outlined, '加入分组', () async {
                final groupId = await _pickGroup(asMembership: true);
                if (groupId != null) {
                  await _run('已加入', (ids) => ShelfApi.addToGroups(ids, groupId));
                }
              }),
              _action(Icons.update, '允许更新', () => _run(
                '已允许更新',
                (ids) => ShelfApi.setCanUpdate(ids, true),
              )),
              _action(Icons.pause_circle_outline, '禁止更新', () => _run(
                '已禁止更新',
                (ids) => ShelfApi.setCanUpdate(ids, false),
              )),
              _action(Icons.swap_horiz, '批量换源', _batchChangeSource),
              _action(Icons.cleaning_services_outlined, '清缓存', _clearCache),
              _action(Icons.delete_outline, '移出书架', _deleteSelected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, Future<void> Function() onTap) {
    final enabled = !_busy && _selected.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextButton.icon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 18),
        label: Text(label),
      ),
    );
  }
}

/// 管理页里复用的小封面，避免再依赖书架页的私有组件。
class _Cover extends StatelessWidget {
  const _Cover({required this.book, required this.size});

  final Map<String, dynamic> book;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: BookCover(
          name: '${book['name'] ?? ''}',
          url: '${book['cover'] ?? ''}',
          width: size,
          height: size * 1.35,
          radius: 3,
          fontSize: size * 0.5,
        ),
      );
}
