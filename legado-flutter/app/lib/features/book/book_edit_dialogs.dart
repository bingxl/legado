import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/book_cover.dart';
import '../shelf/shelf_api.dart';
import '../source/source_api.dart';

/// 编辑书籍信息。返回 true 表示已保存。
///
/// 封面与简介是「覆盖值」：留空即回落到书源抓来的值，不会把原始数据冲掉。
Future<bool> showBookEditDialog(
  BuildContext context,
  Map<String, dynamic> detail,
) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => _BookEditDialog(detail: detail),
  );
  return result == true;
}

class _BookEditDialog extends StatefulWidget {
  const _BookEditDialog({required this.detail});

  final Map<String, dynamic> detail;

  @override
  State<_BookEditDialog> createState() => _BookEditDialogState();
}

class _BookEditDialogState extends State<_BookEditDialog> {
  late final TextEditingController _name =
      TextEditingController(text: '${widget.detail['name'] ?? ''}');
  late final TextEditingController _author =
      TextEditingController(text: '${widget.detail['author'] ?? ''}');
  final TextEditingController _cover = TextEditingController();
  final TextEditingController _intro = TextEditingController();

  List<Map<String, dynamic>> _groups = const [];
  int _groupId = -1;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    _cover.dispose();
    _intro.dispose();
    super.dispose();
  }

  Future<void> _loadGroups() async {
    try {
      final groups = await LegadoClient.instance.callList('Shelf.ListGroups');
      if (!mounted) return;
      setState(() => _groups = groups);
    } on Object {
      // 分组加载失败只影响下拉框，不阻塞编辑。
    }
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '书名不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ShelfApi.saveBook(
        bookId: (widget.detail['id'] as num?)?.toInt() ?? 0,
        name: name,
        author: _author.text,
        coverUrl: _cover.text,
        intro: _intro.text,
        groupId: _groupId,
      );
      if (!mounted) return;
      _close(true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  /// 关闭对话框前先收键盘。
  ///
  /// 输入框还持有焦点时直接 `pop`，安卓端偶发输入连接没关干净，
  /// 用户随后返回详情页会觉得输入法是"自己弹出来的"。
  void _close(bool? result) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline;
    return AlertDialog(
      title: const Text('编辑书籍信息'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '书名',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _author,
                decoration: const InputDecoration(
                  labelText: '作者',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _cover,
                decoration: InputDecoration(
                  labelText: '封面地址（留空用书源封面）',
                  hintText: '${widget.detail['cover'] ?? ''}',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _intro,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '简介（留空用书源简介）',
                  border: OutlineInputBorder(),
                  isDense: true,
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _groupId,
                decoration: const InputDecoration(
                  labelText: '分组',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem(value: -1, child: Text('不修改')),
                  const DropdownMenuItem(value: 0, child: Text('未分组')),
                  for (final group in _groups)
                    DropdownMenuItem(
                      value: (group['id'] as num?)?.toInt() ?? 0,
                      child: Text('${group['name'] ?? ''}'),
                    ),
                ],
                onChanged: (value) => setState(() => _groupId = value ?? -1),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: outline),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => _close(false),
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

/// 换源：全源搜索同名书，返回选中的结果（含 bookUrl），取消返回 null。
Future<Map<String, dynamic>?> showChangeSourceDialog(
  BuildContext context,
  Map<String, dynamic> detail,
) {
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (_) => _ChangeSourceDialog(detail: detail),
  );
}

class _ChangeSourceDialog extends StatefulWidget {
  const _ChangeSourceDialog({required this.detail});

  final Map<String, dynamic> detail;

  @override
  State<_ChangeSourceDialog> createState() => _ChangeSourceDialogState();
}

class _ChangeSourceDialogState extends State<_ChangeSourceDialog> {
  late final TextEditingController _keyword =
      TextEditingController(text: '${widget.detail['name'] ?? ''}');

  List<Map<String, dynamic>> _results = const [];
  bool _searching = false;
  bool _searched = false;
  String? _error;

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) {
      setState(() => _error = '请输入书名');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await SourceApi.searchAll(keyword);
      if (!mounted) return;
      // 同一本书在不同源上 bookUrl 不同；去重按地址，保留首次出现的源。
      final seen = <String>{};
      final unique = [
        for (final item in results)
          if (seen.add('${item['bookUrl'] ?? ''}')) item,
      ];
      setState(() {
        _results = unique;
        _searching = false;
        _searched = true;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searched = true;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('换源'),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _keyword,
                    decoration: const InputDecoration(
                      labelText: '书名',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _searching ? null : _search,
                  child: Text(_searching ? '搜索中…' : '搜索'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '换源会重建目录，并按章节序号保留阅读进度。',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1),
            Expanded(child: _resultList(scheme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _close(),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 关闭前先收键盘（同 `_BookEditDialogState._close`）。
  void _close([Map<String, dynamic>? picked]) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).pop(picked);
  }

  Widget _resultList(ColorScheme scheme) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (!_searched) {
      return Center(
        child: Text('点「搜索」在全部书源里找同名书', style: TextStyle(color: scheme.outline)),
      );
    }
    if (_results.isEmpty) {
      return const Center(child: Text('没有找到其它来源'));
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = _results[index];
        return ListTile(
          dense: true,
          leading: SizedBox(
            width: 34,
            height: 46,
            child: BookCover(
              name: '${item['name'] ?? ''}',
              url: '${item['cover'] ?? ''}',
              width: 34,
              height: 46,
              radius: 3,
              fontSize: 14,
            ),
          ),
          title: Text(
            '${item['name'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${item['originName'] ?? item['origin'] ?? ''}'
            '${'${item['author'] ?? ''}'.isEmpty ? '' : ' · ${item['author']}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          onTap: () => _close(item),
        );
      },
    );
  }
}
