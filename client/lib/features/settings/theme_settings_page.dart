import 'package:flutter/material.dart';

import 'settings_models.dart';
import 'settings_store.dart';
import 'widgets/settings_section_view.dart';
import 'widgets/settings_status_body.dart';

/// 主题外观（`/settings/theme`）。
///
/// 只有 `reader.theme` 需要特化：下拉列表看不出背景色，改成带色卡的横向选择。
/// 其余条目继续走通用渲染，Schema 以后往 theme 页加项不用改这里。
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SettingsStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('主题')),
      body: SettingsStatusBody(
        store: store,
        builder: (context) {
          final sections = store.sectionsForPage('theme');
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final section in sections)
                SettingsSectionView(
                  section: section,
                  store: store,
                  itemBuilder: (item) => item.key == 'reader.theme'
                      ? _ReaderThemePicker(
                          item: item,
                          raw: store.values[item.key] ?? item.defaultRaw,
                          onChanged: (value) => store.setValue(item.key, value),
                        )
                      : null,
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ReaderThemePicker extends StatelessWidget {
  const _ReaderThemePicker({
    required this.item,
    required this.raw,
    required this.onChanged,
  });

  final SettingsItem item;
  final String raw;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: const TextStyle(fontSize: 14)),
          if (item.desc != null) ...[
            const SizedBox(height: 2),
            Text(
              item.desc!,
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              for (final theme in ReaderTheme.presets)
                _ThemeDot(
                  theme: theme,
                  selected: theme.value == raw,
                  onTap: () => onChanged(theme.value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final ReaderTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = theme.background;
    return Semantics(
      selected: selected,
      button: true,
      label: theme.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: background.color,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected
                  ? Icon(Icons.check, size: 18, color: background.textColor)
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              theme.label,
              style: TextStyle(
                fontSize: 12,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
