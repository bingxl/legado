import 'package:flutter/material.dart';

import '../../core/router/routes.dart';
import 'settings_store.dart';
import 'widgets/settings_section_view.dart';
import 'widgets/settings_status_body.dart';

/// 设置中心（`/settings`）。
///
/// 只做三件事：给出阅读/主题两个二级入口、内联渲染 `general` 分组、
/// 提供恢复默认。具体条目全部由 Schema 驱动，后端加项不用改这里。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SettingsStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: SettingsStatusBody(
        store: store,
        builder: (context) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            _EntryTile(
              icon: Icons.text_fields,
              title: '阅读设置',
              subtitle: '字号、行距、页边距、翻页动画',
              onTap: () =>
                  Navigator.of(context).pushNamed(RouteNames.readerSettings),
            ),
            _EntryTile(
              icon: Icons.palette_outlined,
              title: '主题外观',
              subtitle: '阅读背景与夜间模式',
              onTap: () =>
                  Navigator.of(context).pushNamed(RouteNames.themeSettings),
            ),
            const Divider(height: 0.6),
            for (final section in store.sectionsForPage('general'))
              SettingsSectionView(section: section, store: store),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 20, 12, 8),
              child: _ResetButton(store: store),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, size: 20, color: scheme.primary),
      title: Text(title),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: scheme.outline),
      ),
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.outline),
      onTap: onTap,
    );
  }
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.store});

  final SettingsStore store;

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复默认设置'),
        content: const Text('所有设置项都会回到默认值，确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await store.resetAll();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('已恢复默认设置')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.error,
        minimumSize: const Size.fromHeight(44),
      ),
      onPressed: () => _confirm(context),
      child: const Text('恢复默认设置'),
    );
  }
}
