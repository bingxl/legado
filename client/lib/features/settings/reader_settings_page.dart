import 'package:flutter/material.dart';

import 'settings_store.dart';
import 'widgets/settings_section_view.dart';
import 'widgets/settings_status_body.dart';

/// 阅读设置（`/settings/reader`）：渲染 Schema 里 `read` 页的全部分组。
class ReaderSettingsPage extends StatelessWidget {
  const ReaderSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SettingsStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('阅读设置')),
      body: SettingsStatusBody(
        store: store,
        builder: (context) {
          final sections = store.sectionsForPage('read');
          if (sections.isEmpty) {
            return const _Empty();
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              for (final section in sections)
                SettingsSectionView(section: section, store: store),
            ],
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.tune, size: 36, color: scheme.outline),
          const SizedBox(height: 12),
          Text('暂无可调整的阅读设置', style: TextStyle(color: scheme.outline)),
        ],
      ),
    );
  }
}
