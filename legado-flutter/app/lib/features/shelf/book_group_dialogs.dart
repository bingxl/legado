import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import 'shelf_api.dart';

/// 分组管理（对应原版 `ui/book/group/GroupManageDialog`）。
///
/// 分组 id 是位域（2/4/8...），`order` 决定书架顶部 chip 的顺序。
/// 这里只做界面：改名、显隐、拖拽排序、本组排序方式、是否参与目录更新、
/// 封面与删除；真正的落库全部走 `Shelf.*`。
Future<void> showBookGroupManageDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (_) => const _BookGroupManageDialog(),
    );

const _sortLabels = <int, String>{
  -1: '跟随全局',
  0: '按阅读时间',
  1: '按更新时间',
  2: '按书名',
  3: '自定义排序',
  4: '最近阅读/更新',
  5: '按作者',
};

class _BookGroupManageDialog extends StatefulWidget {
  const _BookGroupManageDialog();

  @override
  State<_BookGroupManageDialog> createState() => _BookGroupManageDialogState();
}

class _BookGroupManageDialogState extends State<_BookGroupManageDialog> {
  List<Map<String, dynamic>> _groups = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups = await LegadoClient.instance.callList(Api.shelfListGroups);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loading = false;
        _error = null;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  // 批量分组操作需要多条提示排队，不隐藏上一条。
  void _toast(String message) =>
      showAppToast(context, message, mounted: mounted, replace: false);

  Future<void> _add() async {
    final saved = await showBookGroupEditDialog(context);
    if (saved == true) await _load();
  }

  Future<void> _edit(Map<String, dynamic> group) async {
    final saved = await showBookGroupEditDialog(context, group: group);
    if (saved == true) await _load();
  }

  Future<void> _toggleShow(Map<String, dynamic> group, bool value) async {
    try {
      await ShelfApi.updateGroup(
        (group['id'] as num?)?.toInt() ?? 0,
        name: '${group['name'] ?? ''}',
        show: value,
        order: (group['order'] as num?)?.toInt() ?? 0,
        cover: '${group['cover'] ?? ''}',
        bookSort: (group['bookSort'] as num?)?.toInt() ?? -1,
        enableRefresh: group['enableRefresh'] != false,
      );
      await _load();
    } on LegadoError catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _delete(Map<String, dynamic> group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分组'),
        content: Text(
          '确定删除「${group['name']}」吗？组内书籍会回到未分组，书本身不会被删除。',
        ),
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
    try {
      await ShelfApi.deleteGroup((group['id'] as num?)?.toInt() ?? 0);
      await _load();
    } on LegadoError catch (e) {
      _toast(e.message);
    }
  }

  /// 拖拽排序：按新顺序重写每组的 order（从 1 开始，与 core 的 maxOrder 对齐）。
  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final moved = List<Map<String, dynamic>>.from(_groups);
    final item = moved.removeAt(oldIndex);
    moved.insert(newIndex, item);
    setState(() {
      _groups = [
        for (var i = 0; i < moved.length; i++)
          <String, dynamic>{...moved[i], 'order': i + 1},
      ];
    });
    try {
      for (final group in _groups) {
        await ShelfApi.updateGroup(
          (group['id'] as num?)?.toInt() ?? 0,
          name: '${group['name'] ?? ''}',
          show: group['show'] != false,
          order: (group['order'] as num?)?.toInt() ?? 0,
          cover: '${group['cover'] ?? ''}',
          bookSort: (group['bookSort'] as num?)?.toInt() ?? -1,
          enableRefresh: group['enableRefresh'] != false,
        );
      }
    } on LegadoError catch (e) {
      _toast('排序未保存：${e.message}');
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('分组管理'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!, textAlign: TextAlign.center))
                : _groups.isEmpty
                    ? const Center(child: Text('还没有分组，点左下角新增'))
                    : ReorderableListView.builder(
                        itemCount: _groups.length,
                        onReorder: _reorder,
                        itemBuilder: (_, i) {
                          final group = _groups[i];
                          final sort =
                              (group['bookSort'] as num?)?.toInt() ?? -1;
                          return ListTile(
                            key: ValueKey(group['id']),
                            leading: const Icon(Icons.drag_indicator),
                            title: Text('${group['name'] ?? ''}'),
                            subtitle: Text(
                              '${_sortLabels[sort] ?? '跟随全局'} · '
                              '${group['enableRefresh'] != false ? '参与目录更新' : '跳过目录更新'}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: group['show'] != false,
                                  onChanged: (v) => _toggleShow(group, v),
                                ),
                                IconButton(
                                  tooltip: '编辑',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(group),
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(group),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('新增分组'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

/// 新增 / 编辑一个分组。返回 true 表示已保存。
Future<bool?> showBookGroupEditDialog(
  BuildContext context, {
  Map<String, dynamic>? group,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => _BookGroupEditDialog(group: group),
    );

class _BookGroupEditDialog extends StatefulWidget {
  const _BookGroupEditDialog({this.group});

  final Map<String, dynamic>? group;

  @override
  State<_BookGroupEditDialog> createState() => _BookGroupEditDialogState();
}

class _BookGroupEditDialogState extends State<_BookGroupEditDialog> {
  late final TextEditingController _name = TextEditingController(
    text: '${widget.group?['name'] ?? ''}',
  );
  late final TextEditingController _cover = TextEditingController(
    text: '${widget.group?['cover'] ?? ''}',
  );
  late int _bookSort = (widget.group?['bookSort'] as num?)?.toInt() ?? -1;
  late bool _enableRefresh = widget.group?['enableRefresh'] != false;
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _cover.dispose();
    super.dispose();
  }

  /// 选一张本地图片作为分组封面。
  ///
  /// Android 上 `content://` URI 没有可直接长期使用的文件路径，所以把字节
  /// 复制到应用私有 `covers/` 再存相对稳定的本地路径；这样重启后仍能显示。
  Future<void> _pickCover() async {
    try {
      final result = await FilePicker.pickFiles(type: FileType.image);
      final file = result.singleOrNull;
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final ext = p.extension(file.name).isEmpty
          ? '.png'
          : p.extension(file.name).toLowerCase();
      final dir = Directory(p.join(LegadoClient.instance.homeDir, 'covers'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final target = File(
        p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}$ext'),
      );
      await target.writeAsBytes(bytes, flush: true);
      if (mounted) setState(() => _cover.text = target.path);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('选图失败，可直接在输入框填封面地址')),
        );
      }
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '分组名称不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final id = (widget.group?['id'] as num?)?.toInt() ?? 0;
      if (id > 0) {
        await ShelfApi.updateGroup(
          id,
          name: name,
          show: widget.group?['show'] != false,
          order: (widget.group?['order'] as num?)?.toInt() ?? 0,
          cover: _cover.text.trim(),
          bookSort: _bookSort,
          enableRefresh: _enableRefresh,
        );
      } else {
        // CreateGroup 只收名字，附带的排序/封面/刷新开关用返回的分组视图补写。
        // 不能按名字回查分组列表：分组允许重名，回查可能改到旧的那一个。
        final created = await ShelfApi.createGroup(name);
        await ShelfApi.updateGroup(
          (created['id'] as num?)?.toInt() ?? 0,
          name: name,
          show: created['show'] != false,
          order: (created['order'] as num?)?.toInt() ?? 0,
          cover: _cover.text.trim(),
          bookSort: _bookSort,
          enableRefresh: _enableRefresh,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.group == null ? '新增分组' : '编辑分组'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '分组名称',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _cover,
                      decoration: const InputDecoration(
                        labelText: '封面（可选，本地图片或网址）',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: '从相册选择图片',
                    icon: const Icon(Icons.image_outlined),
                    onPressed: _pickCover,
                  ),
                ],
              ),
              if (_cover.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _cover.text.startsWith('http')
                      ? Image.network(
                          _cover.text,
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            height: 72,
                            child: Center(child: Text('封面加载失败')),
                          ),
                        )
                      : Image.file(
                          File(_cover.text),
                          height: 72,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox(
                            height: 72,
                            child: Center(child: Text('封面文件不存在')),
                          ),
                        ),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _bookSort,
                decoration: const InputDecoration(
                  labelText: '本组排序方式',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final entry in _sortLabels.entries)
                    DropdownMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                onChanged: (v) => setState(() => _bookSort = v ?? -1),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('参与目录更新'),
                subtitle: const Text('书架「更新目录」会包含本组书籍'),
                value: _enableRefresh,
                onChanged: (v) => setState(() => _enableRefresh = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
