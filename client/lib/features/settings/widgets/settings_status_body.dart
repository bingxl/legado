import 'package:flutter/material.dart';

import '../settings_store.dart';

/// 设置页的通用外壳：负责首屏加载、错误态重试，以及保存失败时的提示条。
///
/// 三个页面都只关心「ready 之后长什么样」，省掉各自重复一遍
/// loading/error/snackbar 逻辑，也保证错误文案一致。
class SettingsStatusBody extends StatefulWidget {
  const SettingsStatusBody({
    super.key,
    required this.store,
    required this.builder,
  });

  final SettingsStore store;
  final WidgetBuilder builder;

  @override
  State<SettingsStatusBody> createState() => _SettingsStatusBodyState();
}

class _SettingsStatusBodyState extends State<SettingsStatusBody> {
  late int _seenErrorSeq = widget.store.lastErrorSeq;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onStore);
    widget.store.load();
  }

  @override
  void didUpdateWidget(covariant SettingsStatusBody old) {
    super.didUpdateWidget(old);
    if (!identical(old.store, widget.store)) {
      old.store.removeListener(_onStore);
      widget.store.addListener(_onStore);
      _seenErrorSeq = widget.store.lastErrorSeq;
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    if (!mounted) return;
    setState(() {});
    final seq = widget.store.lastErrorSeq;
    if (seq != _seenErrorSeq) {
      _seenErrorSeq = seq;
      final message = widget.store.lastError;
      if (message != null) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('保存失败：$message')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.store.status) {
      case SettingsStatus.idle:
      case SettingsStatus.loading:
        return const _Skeleton();
      case SettingsStatus.error:
        return _ErrorView(
          message: widget.store.error ?? '设置加载失败',
          onRetry: () => widget.store.load(force: true),
        );
      case SettingsStatus.ready:
        return widget.builder(context);
    }
  }
}

/// 骨架屏：固定几个灰块，比整屏转圈更接近最终版式，也不会闪一下白屏。
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6);
    return ListView(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Container(
              height: i == 0 ? 56 : 104,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
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
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
