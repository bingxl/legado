import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'rss_api.dart';
import 'rss_source_edit_page.dart';
import 'rss_text.dart';

/// 订阅源管理 tab。
///
/// 数据由外层 [RssHomePage] 统一持有（源列表同时决定文章 tab 的筛选项），
/// 这里只做行的渲染与动作：改启用、刷新单个源、编辑、滑动删除。
/// 动作完成后统一回调 `onChanged`，让外层重拉并广播给另一个 tab。
class RssSourceTab extends StatefulWidget {
  const RssSourceTab({
    super.key,
    required this.sources,
    required this.onChanged,
  });

  final List<Map<String, dynamic>> sources;

  /// 重拉源列表（外层负责）。返回的 Future 供下拉刷新等待。
  final Future<void> Function() onChanged;

  @override
  State<RssSourceTab> createState() => _RssSourceTabState();
}

/// 行内菜单动作。
enum _RowAction { refresh, edit, delete }

class _RssSourceTabState extends State<RssSourceTab> {
  /// 正在写 core 的源 id：行尾显示转圈并禁止重复点击。
  final Set<int> _busy = <int>{};

  /// 最近一次刷新失败的原因（core 的 Source dto 不带 lastError，只能自己记）。
  final Map<int, String> _lastErrors = <int, String>{};

  /// 本地行数据：滑动删除要先把行摘掉，等外层重拉后再整体替换。
  late List<Map<String, dynamic>> _rows = widget.sources;

  @override
  void didUpdateWidget(covariant RssSourceTab old) {
    super.didUpdateWidget(old);
    if (!identical(old.sources, widget.sources)) {
      _rows = widget.sources;
      // 源被删掉后，它对应的错误信息也没有意义了。
      final alive = _rows.map((s) => rssInt(s['id'])).toSet();
      _lastErrors.removeWhere((id, _) => !alive.contains(id));
    }
  }

  Future<void> _reload() async {
    await widget.onChanged();
  }

  Future<void> _setEnabled(int id, bool enabled) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await RssApi.setSourceEnabled(id, enabled);
      if (!mounted) return;
      // 先本地翻转，外层重拉回来之前开关不会弹回原位。
      setState(() {
        _rows = [
          for (final s in _rows)
            if (rssInt(s['id']) == id) {...s, 'enabled': enabled} else s,
        ];
      });
      await widget.onChanged();
    } on LegadoError catch (e) {
      if (mounted) _toast('${e.code}: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _refreshOne(int id, String name) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      final result = await RssApi.refreshArticles(id);
      final errors = (result['errors'] as List?) ?? const [];
      final error = errors.isEmpty ? null : '${errors.first}';
      final added = rssInt(result['added']);
      final updated = rssInt(result['updated']);
      if (!mounted) return;
      setState(() {
        if (error == null) {
          _lastErrors.remove(id);
        } else {
          _lastErrors[id] = error;
        }
      });
      _toast(
        error == null
            ? '「$name」已刷新：新增 $added 篇，更新 $updated 篇'
            : '「$name」刷新失败：$error',
      );
      await widget.onChanged();
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() => _lastErrors[id] = '${e.code}: ${e.message}');
      _toast('刷新失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastErrors[id] = '$e');
      _toast('刷新失败：$e');
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<bool> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除订阅源'),
        content: Text('确定删除「$name」？该源下的文章与收藏会一并删除，且不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    return ok == true;
  }

  /// 滑动动画结束后再真正删除：失败时外层重拉会把行带回来。
  Future<void> _delete(int id, String name) async {
    setState(() => _rows.removeWhere((s) => rssInt(s['id']) == id));
    try {
      await RssApi.deleteSource(id);
      if (!mounted) return;
      _toast('已删除「$name」');
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('删除失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast('删除失败：$e');
    }
    await widget.onChanged();
  }

  Future<void> _openEdit(int id) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => RssSourceEditPage(sourceId: id)),
    );
    if (changed == true) await widget.onChanged();
  }

  Future<void> _onAction(_RowAction action, Map<String, dynamic> source) async {
    final id = rssInt(source['id']);
    final name = _nameOf(source);
    switch (action) {
      case _RowAction.refresh:
        await _refreshOne(id, name);
      case _RowAction.edit:
        await _openEdit(id);
      case _RowAction.delete:
        if (await _confirmDelete(name) && mounted) await _delete(id, name);
    }
  }

  static String _nameOf(Map<String, dynamic> source) {
    final name = '${source['name'] ?? ''}'.trim();
    return name.isEmpty ? RssText.hostOf('${source['url'] ?? ''}') : name;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 120),
            Center(
              child: Text(
                '还没有订阅源，点右下角新增',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _rows.length,
        separatorBuilder: (_, _) => const Divider(height: 0.6, indent: 16),
        itemBuilder: (_, i) => _row(_rows[i]),
      ),
    );
  }

  Widget _row(Map<String, dynamic> source) {
    final scheme = Theme.of(context).colorScheme;
    final id = rssInt(source['id']);
    final name = _nameOf(source);
    final url = '${source['url'] ?? ''}'.trim();
    final group = '${source['group'] ?? ''}'.trim();
    final enabled = source['enabled'] == true;
    final unread = rssInt(source['unreadCount']);
    final error = _lastErrors[id];
    final busy = _busy.contains(id);

    return Dismissible(
      key: ValueKey('rss-source-$id'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.delete_outline, color: scheme.onErrorContainer),
      ),
      confirmDismiss: (_) => _confirmDelete(name),
      onDismissed: (_) => _delete(id, name),
      child: ListTile(
        onTap: busy ? null : () => _openEdit(id),
        leading: Icon(
          enabled ? Icons.rss_feed : Icons.rss_feed_outlined,
          color: enabled ? scheme.primary : scheme.outline,
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  unread > 99 ? '99+' : '$unread',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            if (!enabled)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  '已停用',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${group.isEmpty ? '未分组' : group} · $url',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (error != null)
              Text(
                '最近刷新失败：$error',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: scheme.error),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
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
                  onChanged: (value) => _setEnabled(id, value),
                ),
              ),
            PopupMenuButton<_RowAction>(
              tooltip: '更多',
              onSelected: (action) => _onAction(action, source),
              itemBuilder: (_) => const [
                PopupMenuItem(value: _RowAction.refresh, child: Text('立即刷新')),
                PopupMenuItem(value: _RowAction.edit, child: Text('编辑')),
                PopupMenuItem(value: _RowAction.delete, child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
