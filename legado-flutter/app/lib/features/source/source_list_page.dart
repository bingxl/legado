import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'source_api.dart';
import 'source_debug_page.dart';
import 'source_edit_page.dart';
import 'source_utils.dart';

/// 书源管理页（对应原版 `ui/book/source/manage/BookSourceActivity`）。
///
/// pickMode 为 true 时退化为「选择器」：不显示增删改入口，点击一行直接
/// `Navigator.pop` 回书源 dto，供其他页面（订阅、搜索范围等）复用。
class SourceListPage extends StatefulWidget {
  const SourceListPage({super.key, this.pickMode = false});

  /// 选择模式：只读 + 点选返回。
  final bool pickMode;

  @override
  State<SourceListPage> createState() => _SourceListPageState();
}

/// 单行菜单动作。
enum _SourceAction { edit, group, check, debug, delete }

class _SourceListPageState extends State<SourceListPage> {
  List<Map<String, dynamic>> _sources = const [];
  List<Map<String, dynamic>> _groups = const [];
  bool _loading = true;
  String? _error;

  String _query = '';
  String _groupFilter = '';

  /// 多选模式与已选 id。
  bool _selecting = false;
  final Set<int> _selected = <int>{};

  /// 正在后台校验的书源 id，行尾会显示转圈。
  final Set<int> _checking = <int>{};

  /// 全屏级操作（导入）进行中，挡住重复点击。
  bool _bulkBusy = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await SourceApi.list();
      final groups = await SourceApi.listGroups();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _groups = groups;
        _loading = false;
        // 数据刷新后剔除已不存在的选中项。
        final alive = sources.map(_idOf).toSet();
        _selected.removeWhere((id) => !alive.contains(id));
        if (_selected.isEmpty) _selecting = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      // bridge 未初始化时 instance 会抛 StateError，别把红屏丢给用户。
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  static int _idOf(Map<String, dynamic> s) => (s['id'] as num?)?.toInt() ?? 0;

  List<Map<String, dynamic>> get _filtered => _sources
      .where((s) => SourceUtils.inGroup(s, _groupFilter))
      .where((s) => SourceUtils.matchesQuery(s, _query))
      .toList(growable: false);

  // ── 页面骨架 ────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _appBar(),
      body: Column(
        children: [
          _searchField(),
          _groupBar(),
          const Divider(height: 0.6),
          Expanded(child: _content()),
        ],
      ),
      floatingActionButton: widget.pickMode || _selecting ? null : _fab(),
      bottomNavigationBar: _selecting ? _batchBar() : null,
    );
  }

  PreferredSizeWidget _appBar() {
    if (_selecting) {
      return AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '退出多选',
          onPressed: _exitSelection,
        ),
        title: Text('已选 ${_selected.length} 项'),
        actions: [
          IconButton(
            tooltip: '全选',
            icon: const Icon(Icons.select_all),
            onPressed: _toggleSelectAll,
          ),
        ],
      );
    }
    return AppBar(
      title: Text(widget.pickMode ? '选择书源' : '书源管理'),
      // 导入是长操作（要下载 + 逐条解析），进度条给一个明确的「还在跑」。
      bottom: _bulkBusy
          ? const PreferredSize(
              preferredSize: Size.fromHeight(2),
              child: LinearProgressIndicator(minHeight: 2),
            )
          : null,
      actions: [
        IconButton(
          tooltip: '分组管理',
          icon: const Icon(Icons.folder_outlined),
          onPressed: _showGroupManager,
        ),
        IconButton(
          tooltip: '刷新',
          icon: const Icon(Icons.refresh),
          onPressed: _reload,
        ),
      ],
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索名称 / 地址 / 分组',
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
      ),
    );
  }

  Widget _groupBar() {
    final total = _sources.length;
    final items = <Map<String, dynamic>>[
      {'name': '', 'count': total},
      ..._groups,
    ];
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final g = items[i];
          final name = '${g['name'] ?? ''}';
          final count = (g['count'] as num?)?.toInt() ?? 0;
          final selected = name == _groupFilter;
          return ChoiceChip(
            label: Text(name.isEmpty ? '全部 ($count)' : '$name ($count)'),
            selected: selected,
            onSelected: (_) =>
                setState(() => _groupFilter = selected ? '' : name),
          );
        },
      ),
    );
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 36),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      final empty = _sources.isEmpty ? '还没有书源，点右下角新建或导入' : '没有匹配的书源';
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          children: [
            SizedBox(height: 120),
            Center(child: Text(empty)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: list.length,
        separatorBuilder: (_, _) => const Divider(height: 0.6, indent: 16),
        itemBuilder: (_, i) => _row(list[i]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> source) {
    final id = _idOf(source);
    final enabled = source['enabled'] == true;
    final name = '${source['name'] ?? ''}';
    final group = '${source['group'] ?? ''}'.trim();
    final host = SourceUtils.domainOf('${source['url'] ?? ''}');
    final checked = _selected.contains(id);

    return ListTile(
      selected: checked,
      onTap: () {
        if (_selecting) {
          _toggleSelected(id);
        } else if (widget.pickMode) {
          Navigator.of(context).pop(source);
        } else {
          _openEdit(id);
        }
      },
      onLongPress: _selecting ? null : () => _beginSelection(id),
      leading: _selecting
          ? Checkbox(value: checked, onChanged: (_) => _toggleSelected(id))
          : Icon(
              enabled ? Icons.public : Icons.public_off,
              color: enabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outline,
            ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              name.isEmpty ? host : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!enabled)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: _Tag(text: '已禁用'),
            ),
        ],
      ),
      subtitle: Text(
        '${group.isEmpty ? '未分组' : group} · $host',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_checking.contains(id))
                  const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: enabled,
                      onChanged: (v) => _setEnabled(id, v),
                    ),
                  ),
                PopupMenuButton<_SourceAction>(
                  tooltip: '更多',
                  onSelected: (a) => _onAction(a, source),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: _SourceAction.edit, child: Text('编辑')),
                    PopupMenuItem(
                      value: _SourceAction.group,
                      child: Text('加入分组'),
                    ),
                    PopupMenuItem(
                      value: _SourceAction.check,
                      child: Text('校验'),
                    ),
                    PopupMenuItem(
                      value: _SourceAction.debug,
                      child: Text('调试'),
                    ),
                    PopupMenuItem(
                      value: _SourceAction.delete,
                      child: Text('删除'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  // ── 多选 ────────────────────────────────────────────────

  void _beginSelection(int id) {
    setState(() {
      _selecting = true;
      _selected.add(id);
    });
  }

  void _toggleSelected(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _toggleSelectAll() {
    final all = _filtered.map(_idOf).toSet();
    setState(() {
      if (_selected.length == all.length && all.containsAll(_selected)) {
        _selected.clear();
        _selecting = false;
      } else {
        _selected
          ..clear()
          ..addAll(all);
      }
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Widget _batchBar() {
    return SafeArea(
      child: Material(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _barAction(
                Icons.check_circle_outline,
                '启用',
                () => _batchEnabled(true),
              ),
              _barAction(Icons.block, '禁用', () => _batchEnabled(false)),
              _barAction(
                Icons.folder_outlined,
                '分组',
                () => _moveToGroup(_selected.toList()),
              ),
              _barAction(Icons.delete_outline, '删除', _batchDelete),
              _barAction(Icons.close, '取消', _exitSelection),
            ],
          ),
        ),
      ),
    );
  }

  Widget _barAction(IconData icon, String label, VoidCallback onTap) {
    return TextButton(
      onPressed: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  // ── 行内动作 ────────────────────────────────────────────

  Future<void> _onAction(
    _SourceAction action,
    Map<String, dynamic> source,
  ) async {
    final id = _idOf(source);
    switch (action) {
      case _SourceAction.edit:
        await _openEdit(id);
      case _SourceAction.group:
        await _moveToGroup([id]);
      case _SourceAction.check:
        await _check(id);
      case _SourceAction.debug:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceDebugPage(initialSourceId: id),
          ),
        );
      case _SourceAction.delete:
        await _confirmDelete([id], name: '${source['name'] ?? ''}');
    }
  }

  Future<void> _openEdit(int id) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SourceEditPage(sourceId: id)),
    );
    if (changed == true) await _reload();
  }

  Future<void> _setEnabled(int id, bool enabled) async {
    setState(() => _checking.add(id)); // 借用行尾转圈表示「正在写」
    try {
      await SourceApi.setEnabled(id, enabled);
      if (!mounted) return;
      setState(() {
        _sources = [
          for (final s in _sources)
            if (_idOf(s) == id) {...s, 'enabled': enabled} else s,
        ];
      });
    } on LegadoError catch (e) {
      if (mounted) _snack('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _checking.remove(id));
    }
  }

  Future<void> _batchEnabled(bool enabled) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      await SourceApi.setEnabledBatch(ids, enabled);
      _snack('已${enabled ? '启用' : '禁用'} ${ids.length} 个书源');
      _exitSelection();
      await _reload();
    } on LegadoError catch (e) {
      _snack('${e.code}: ${e.message}');
    }
  }

  Future<void> _batchDelete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final ok = await _confirmDelete(
      ids,
      name: '${ids.length} 个书源',
      batch: true,
    );
    if (ok != true) return;
    try {
      await SourceApi.deleteBatch(ids);
      _snack('已删除 ${ids.length} 个书源');
      _exitSelection();
      await _reload();
    } on LegadoError catch (e) {
      _snack('${e.code}: ${e.message}');
    }
  }

  /// 删除确认。返回 true 表示用户确认（调用方负责真正删除）。
  Future<bool?> _confirmDelete(
    List<int> ids, {
    required String name,
    bool batch = false,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书源'),
        content: Text('确定删除「$name」？该操作不可撤销。'),
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
    if (ok != true) return ok;
    if (batch) return true;
    try {
      await SourceApi.delete(ids.first);
      _snack('已删除');
      await _reload();
      return true;
    } on LegadoError catch (e) {
      _snack('${e.code}: ${e.message}');
      return false;
    }
  }

  /// 加入分组：可选已有分组，也可手填新分组名。
  Future<void> _moveToGroup(List<int> ids) async {
    if (ids.isEmpty) return;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加入分组'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_groups.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final g in _groups)
                      ActionChip(
                        label: Text('${g['name'] ?? ''}'),
                        onPressed: () =>
                            Navigator.pop(ctx, '${g['name'] ?? ''}'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '新分组名',
                  hintText: '留空则取消',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('加入'),
          ),
        ],
      ),
    );
    controller.dispose();
    final group = result?.trim() ?? '';
    if (group.isEmpty) return;
    try {
      await SourceApi.addToGroup(ids, group);
      _snack('已加入分组「$group」');
      _exitSelection();
      await _reload();
    } on LegadoError catch (e) {
      _snack('${e.code}: ${e.message}');
    }
  }

  // ── 校验 ────────────────────────────────────────────────

  Future<void> _check(int id) async {
    final keyword = await _askKeyword();
    if (keyword == null) return;
    setState(() => _checking.add(id));
    try {
      final results = await SourceApi.validate(
        [id],
        search: true,
        info: true,
        toc: true,
        content: true,
        keyword: keyword,
      );
      if (!mounted) return;
      await _showCheckResult(results);
    } on LegadoError catch (e) {
      if (mounted) _snack('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _checking.remove(id));
    }
  }

  Future<String?> _askKeyword() async {
    final controller = TextEditingController(text: '我的');
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('校验关键词'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '用于搜索校验',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('开始校验'),
          ),
        ],
      ),
    );
    controller.dispose();
    return v;
  }

  Future<void> _showCheckResult(List<Map<String, dynamic>> results) async {
    if (results.isEmpty) {
      _snack('校验没有返回结果');
      return;
    }
    final r = results.first;
    final ok = r['ok'] == true;
    final issues = (r['issues'] as List?) ?? const [];
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              ok ? Icons.check_circle_outline : Icons.error_outline,
              color: ok ? Colors.green : Theme.of(ctx).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('${r['sourceName'] ?? '校验结果'}')),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: issues.isEmpty
              ? const Text('没有发现问题。')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: issues.length,
                  separatorBuilder: (_, _) => const Divider(height: 12),
                  itemBuilder: (_, i) {
                    final issue = (issues[i] as Map).cast<String, dynamic>();
                    final level = '${issue['level'] ?? ''}';
                    final miss = SourceUtils.isMiss(
                      level,
                      '${issue['message'] ?? ''}',
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          miss
                              ? Icons.cancel_outlined
                              : level == 'warning'
                              ? Icons.warning_amber_outlined
                              : Icons.info_outline,
                          size: 18,
                          color: miss
                              ? Theme.of(ctx).colorScheme.error
                              : level == 'warning'
                              ? Colors.orange
                              : Theme.of(ctx).colorScheme.outline,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${issue['message'] ?? ''}'),
                              Text(
                                '${issue['field'] ?? ''}',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(ctx).colorScheme.outline,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ── 分组管理 ────────────────────────────────────────────

  Future<void> _showGroupManager() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _GroupManagerDialog(groups: _groups),
    );
    if (changed == true) await _reload();
  }

  // ── 新建 / 导入 ─────────────────────────────────────────

  Widget _fab() {
    return FloatingActionButton(
      tooltip: '新建或导入',
      onPressed: _showCreateSheet,
      child: const Icon(Icons.add),
    );
  }

  Future<void> _showCreateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: const Text('新建书源'),
              onTap: () {
                Navigator.pop(ctx);
                _openCreate();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_go),
              title: const Text('粘贴 JSON 导入'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromText();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('从文件导入'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('从 URL 导入'),
              onTap: () {
                Navigator.pop(ctx);
                _importFromUrl();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _openCreate() async {
    final changed = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const SourceEditPage()));
    if (changed == true) await _reload();
  }

  Future<void> _importFromText() async {
    final controller = TextEditingController();
    var overwrite = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('粘贴书源 JSON'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  minLines: 6,
                  maxLines: 12,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: '支持单个书源对象、书源数组或备份文件',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: overwrite,
                  onChanged: (v) => setLocal(() => overwrite = v),
                  title: const Text('覆盖同地址书源'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    final text = controller.text;
    controller.dispose();
    if (ok != true) return;
    if (text.trim().isEmpty) {
      _snack('内容为空');
      return;
    }
    await _runImport(() => SourceApi.importText(text, overwrite: overwrite));
  }

  Future<void> _importFromUrl() async {
    final controller = TextEditingController();
    var overwrite = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('从 URL 导入'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '书源 JSON 地址',
                    hintText: 'https://…/bookSource.json',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: overwrite,
                  onChanged: (v) => setLocal(() => overwrite = v),
                  title: const Text('覆盖同地址书源'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    final url = controller.text.trim();
    controller.dispose();
    if (ok != true || url.isEmpty) return;
    await _runImport(() => SourceApi.importFromUrl(url, overwrite: overwrite));
  }

  /// 从本地文件导入：文件选择器只负责拿到文本，去重/落库仍走 core。
  Future<void> _importFromFile() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择书源 JSON 文件',
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
    } catch (e) {
      _snack('打开文件失败: $e');
      return;
    }
    if (!mounted || picked.isEmpty) return;

    final file = picked.first;
    String text;
    try {
      // Android 的 content:// 没有可读 path；file_picker 统一封装成 readAsBytes。
      text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } catch (e) {
      _snack('读取文件失败: $e');
      return;
    }
    if (text.trim().isEmpty) {
      _snack('文件内容为空');
      return;
    }
    if (!mounted) return;

    var overwrite = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('导入书源文件'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                file.name,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: overwrite,
                onChanged: (v) => setLocal(() => overwrite = v),
                title: const Text('覆盖同地址书源'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _runImport(() => SourceApi.importText(text, overwrite: overwrite));
  }

  /// 执行导入并展示汇总结果。
  Future<void> _runImport(Future<Map<String, dynamic>> Function() task) async {
    setState(() => _bulkBusy = true);
    try {
      final result = await task();
      if (!mounted) return;
      final msg = SourceUtils.importSummary(result);
      final firstFailure = SourceUtils.firstImportFailure(result);
      _snack(firstFailure == null ? msg : '$msg（$firstFailure）');
      await _reload();
    } on LegadoError catch (e) {
      if (mounted) _snack('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _bulkBusy = false);
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}

/// 分组管理对话框：重命名 / 删除 / 新建。
class _GroupManagerDialog extends StatefulWidget {
  const _GroupManagerDialog({required this.groups});

  final List<Map<String, dynamic>> groups;

  @override
  State<_GroupManagerDialog> createState() => _GroupManagerDialogState();
}

class _GroupManagerDialogState extends State<_GroupManagerDialog> {
  late List<Map<String, dynamic>> _groups = widget.groups;
  bool _changed = false;

  Future<void> _rename(String oldName) async {
    final controller = TextEditingController(text: oldName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == oldName) return;
    await _guard(() => SourceApi.renameGroup(oldName, trimmed));
  }

  Future<void> _delete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组'),
        content: Text('删除分组「$name」？组内书源会变成未分组，不会被删除。'),
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
    await _guard(() => SourceApi.deleteGroup(name));
  }

  Future<void> _create() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分组'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '分组名（建好后在书源菜单里加入）',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    // core 没有「空分组」概念：分组由书源字段聚合而来，
    // 因此这里只能提示用户用「加入分组」落第一个源。
    if (name != null && name.trim().isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('分组「${name.trim()}」会在书源加入后出现')));
      }
    }
  }

  Future<void> _guard(Future<void> Function() task) async {
    try {
      await task();
      _changed = true;
      // 重新拉分组，保证计数准确。
      final groups = await SourceApi.listGroups();
      if (!mounted) return;
      setState(() => _groups = groups);
    } on LegadoError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${e.code}: ${e.message}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('分组管理'),
      content: SizedBox(
        width: 420,
        height: 320,
        child: _groups.isEmpty
            ? const Center(child: Text('还没有分组'))
            : ListView.separated(
                itemCount: _groups.length,
                separatorBuilder: (_, _) => const Divider(height: 0.6),
                itemBuilder: (_, i) {
                  final g = _groups[i];
                  final name = '${g['name'] ?? ''}';
                  final count = (g['count'] as num?)?.toInt() ?? 0;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(name),
                    subtitle: Text('$count 个书源'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: '重命名',
                          icon: const Icon(Icons.edit_outlined, size: 20),
                          onPressed: () => _rename(name),
                        ),
                        IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _delete(name),
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
      actions: [
        TextButton(onPressed: _create, child: const Text('新建分组')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _changed),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 列表行里的小标签。
class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
