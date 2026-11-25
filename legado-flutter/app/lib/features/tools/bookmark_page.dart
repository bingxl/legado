import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/router/routes.dart';
import 'tools_api.dart';
import 'tools_format.dart';

/// 书签页（对应原版 `ui/bookmark/BookmarkActivity`）。
///
/// core 的 `Bookmark.List` 一次给全量（这里取 200 条），Dart 侧只做
/// 按日期分组渲染；增删改都即时回写 core，本地不缓存业务状态。
class BookmarkPage extends StatefulWidget {
  const BookmarkPage({super.key});

  @override
  State<BookmarkPage> createState() => _BookmarkPageState();
}

class _BookmarkPageState extends State<BookmarkPage> {
  /// 200 条足够覆盖「最近的书签」；真要做全量分页，得等 core 给出总数。
  static const int _limit = 200;

  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final list = await ToolsApi.bookmarks(0, _limit);
      if (!mounted) return;
      setState(() {
        _items = list;
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

  /// 跳阅读器定位到书签所在章节的章内位置。
  ///
  /// 键名走 `reader_page.dart` 的路由契约（`chapterIndex` + `chapterPos`）：
  /// 另一个名字（`initialChapter`）是构造参数名，阅读页也认但没必要重复传。
  /// `chapterPos` 必须一起传 —— 原版 `Bookmark.readChapter` 也是先把
  /// `durChapterPos` 写成书签位置再打开阅读器，否则只跳到章首，书签白设。
  void _open(Map<String, dynamic> item) {
    Navigator.pushNamed(
      context,
      RouteNames.reader,
      arguments: {
        'bookId': toolsInt(item['bookId']),
        'chapterIndex': toolsInt(item['chapterIndex']),
        'chapterPos': toolsInt(item['chapterPos']),
      },
    );
  }

  /// Dismissible 已经把条目从树里移除，本地列表必须同步删掉，
  /// 否则下一帧会因「同一 key 找不到」抛错。
  Future<void> _remove(Map<String, dynamic> item) async {
    final id = toolsInt(item['id']);
    setState(() {
      _items = [
        for (final it in _items)
          if (toolsInt(it['id']) != id) it,
      ];
    });
    try {
      await ToolsApi.bookmarkRemove(id);
      if (!mounted) return;
      _toast('已删除书签');
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('删除失败：${e.message}');
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败：$e');
      await _load(silent: true);
    }
  }

  Future<void> _editNote(Map<String, dynamic> item) async {
    final controller = TextEditingController(text: toolsStr(item['note']));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(hintText: '写点备注，留空则清除'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null) return;
    try {
      await ToolsApi.bookmarkUpdateNote(toolsInt(item['id']), result);
      if (!mounted) return;
      _toast(result.isEmpty ? '已清除备注' : '备注已保存');
      await _load(silent: true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('保存失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('保存失败：$e');
    }
  }

  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书签'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(silent: true),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _errorState(_error!);
    if (_items.isEmpty) return _emptyState();

    // 分组是扁平化的：日期标题与条目同级，方便 Dismissible 与下拉刷新共存。
    final groups = groupByDay(_items, (it) => parseTime(it['createdAt']));
    final children = <Widget>[];
    for (final group in groups) {
      children.add(_groupHeader(group.label));
      for (final item in group.items) {
        children.add(_dismissibleRow(item));
      }
    }

    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: children,
      ),
    );
  }

  Widget _groupHeader(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.outline,
        ),
      ),
    );
  }

  Widget _dismissibleRow(Map<String, dynamic> item) {
    return Dismissible(
      key: ValueKey('bookmark-${toolsInt(item['id'])}'),
      // 左右滑都接受：桌面端用鼠标拖动，方向意图常常不精确。
      direction: DismissDirection.horizontal,
      background: _swipeBackground(Alignment.centerLeft),
      secondaryBackground: _swipeBackground(Alignment.centerRight),
      onDismissed: (_) => _remove(item),
      child: _bookmarkRow(item),
    );
  }

  Widget _swipeBackground(Alignment alignment) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.error,
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Icon(Icons.delete_outline, color: scheme.onError),
    );
  }

  Widget _bookmarkRow(Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final title = toolsStr(item['chapterTitle']).trim();
    final content = toolsStr(item['content']).trim();
    final note = toolsStr(item['note']).trim();
    final time = parseTime(item['createdAt']);

    return InkWell(
      onTap: () => _open(item),
      onLongPress: () => _editNote(item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title.isEmpty ? '未命名章节' : title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (time != null)
                        Text(
                          formatClock(time),
                          style: TextStyle(fontSize: 11, color: scheme.outline),
                        ),
                    ],
                  ),
                  if (content.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      content,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  if (note.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        note,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: '编辑备注',
              icon: const Icon(Icons.edit_note, size: 20),
              onPressed: () => _editNote(item),
            ),
          ],
        ),
      ),
    );
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
          Icon(Icons.bookmark_border, size: 36, color: scheme.outline),
          const SizedBox(height: 12),
          Center(
            child: Text('还没有书签', style: TextStyle(color: scheme.outline)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '在阅读器里点书签按钮，记录喜欢的段落',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}
