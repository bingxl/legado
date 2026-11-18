import 'package:flutter/material.dart';

import '../settings_models.dart';
import '../settings_store.dart';
import 'settings_control.dart';

/// 一个 Schema 分组的通用渲染：标题 + 说明 + 若干条目。
///
/// 三个设置页共用它，保证「阅读设置/主题/通用」的间距与分隔线完全一致；
/// 特殊控件（如主题色卡）由页面自己替换单个 item，而不是另写一套分组。
class SettingsSectionView extends StatelessWidget {
  const SettingsSectionView({
    super.key,
    required this.section,
    required this.store,
    this.itemBuilder,
  });

  final SettingsSection section;
  final SettingsStore store;

  /// 返回非 null 时覆盖默认控件，用于把某个 key 特化（例如 reader.theme）。
  final Widget? Function(SettingsItem item)? itemBuilder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final desc = section.desc;
    final children = <Widget>[];
    for (var i = 0; i < section.items.length; i++) {
      final item = section.items[i];
      final custom = itemBuilder?.call(item);
      final raw = store.values[item.key] ?? item.defaultRaw;
      children.add(
        custom ??
            SettingsControl(
              item: item,
              raw: raw,
              display: store.displayValue(item, raw),
              onChanged: (value) => store.setValue(item.key, value),
            ),
      );
      if (i < section.items.length - 1) {
        children.add(const Divider(height: 0.6, indent: 16, endIndent: 16));
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (desc != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ],
              ],
            ),
          ),
          Material(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}
