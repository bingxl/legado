import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';
import 'tools_api.dart';
import 'tools_format.dart';

/// 阅读记录页（对应原版 `ui/bookmark/ReadRecordActivity`）。
///
/// 记录由阅读器在翻章时写入 core 的 read_record 表（同书同日同章只留一条），
/// 本页只负责展示与清理，不做去重。
class RecordPage extends StatefulWidget {
  const RecordPage({super.key});

  @override
  State<RecordPage> createState() => _RecordPageState();
}

class _RecordPageState extends State<RecordPage> {
  static const int _limit = 200;

  Map<String, dynamic> _stats = const {};
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
      final stats = await ToolsApi.recordStats();
      final list = await ToolsApi.records(0, _limit);
      if (!mounted) return;
      setState(() {
        _stats = stats;
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

  /// 清理：7 天 / 30 天 / 全部。返回值就是 `Record.Clear(beforeDays)`
  /// 的参数——core 的语义是「删除 N 天之前的记录」，所以文案写「保留」。
  Future<void> _openClear() async {
    final days = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('清理阅读记录'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(7),
            child: const Text('保留最近 7 天'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(30),
            child: const Text('保留最近 30 天'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(ctx).pop(0),
            child: Text(
              '全部清空',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (days == null) return;
    if (days == 0) {
      // 全部清空不可撤销，单独再确认一次。
      final ok = await _confirmClearAll();
      if (!ok) return;
    }
    try {
      final removed = await ToolsApi.recordClear(days);
      if (!mounted) return;
      _toast(removed <= 0 ? '没有需要清理的记录' : '已清理 $removed 条记录');
      await _load(silent: true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('清理失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('清理失败：$e');
    }
  }

  Future<bool> _confirmClearAll() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部清空'),
        content: const Text('将删除所有阅读记录，统计会一并归零。确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    return result == true;
  }

  void _open(Map<String, dynamic> item) {
    final chapter = toolsInt(item['chapterIndex']);
    Navigator.pushNamed(
      context,
      RouteNames.reader,
      arguments: {'bookId': toolsInt(item['bookId']), 'chapterIndex': chapter},
    );
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
        title: const Text('阅读记录'),
        actions: [
          IconButton(
            tooltip: '清理记录',
            icon: const Icon(Icons.cleaning_services_outlined),
            onPressed: _openClear,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      child: Row(
        children: [
          _StatCell(value: '${toolsInt(_stats['days'])}', label: '阅读天数'),
          _StatCell(value: '${toolsInt(_stats['books'])}', label: '涉及书籍'),
          _StatCell(value: '${toolsInt(_stats['records'])}', label: '记录条数'),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _errorState(_error!);
    if (_items.isEmpty) return _emptyState();

    final groups = groupByDay(_items, (it) => parseTime(it['readAt']));
    final children = <Widget>[];
    for (final group in groups) {
      children.add(_groupHeader(group.label));
      for (final item in group.items) {
        children.add(_recordRow(item));
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

  Widget _recordRow(Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final bookName = toolsStr(item['bookName']).trim();
    final chapterTitle = toolsStr(item['chapterTitle']).trim();
    final time = parseTime(item['readAt']);

    return InkWell(
      onTap: () => _open(item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    bookName.isEmpty ? '未知书籍' : bookName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chapterTitle.isEmpty ? '未知章节' : chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              time == null ? '' : formatClock(time),
              style: TextStyle(fontSize: 12, color: scheme.outline),
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
          Icon(Icons.history, size: 36, color: scheme.outline),
          const SizedBox(height: 12),
          Center(
            child: Text('还没有阅读记录', style: TextStyle(color: scheme.outline)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              '读书时翻过的章节会自动记录在这里',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

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
