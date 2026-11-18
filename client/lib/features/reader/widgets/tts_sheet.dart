import 'package:flutter/material.dart';

import '../reader_controller.dart';

/// 朗读入口。
///
/// 音频播放还没接，但 `Tts.Segment` 已经在 core 侧可用：
/// 先把当前页切成句子给用户预览，等播放器接入后直接按这些片段排队即可。
/// 这样 UI 侧的分段逻辑现在就能被验证，不必等音频引擎。
Future<void> showTtsSheet(BuildContext context, ReaderController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _TtsSheet(controller: controller),
  );
}

class _TtsSheet extends StatefulWidget {
  const _TtsSheet({required this.controller});

  final ReaderController controller;

  @override
  State<_TtsSheet> createState() => _TtsSheetState();
}

class _TtsSheetState extends State<_TtsSheet> {
  /// 只在打开面板时请求一次分段，避免重建（如键盘事件）把 RPC 重复打出去。
  late final Future<List<Map<String, dynamic>>> _segments = widget.controller
      .segmentCurrentPage();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.55,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.record_voice_over_outlined, size: 20),
                const SizedBox(width: 8),
                Text('朗读', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '当前页「${widget.controller.chapterTitle}」的分段结果',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 0.6),
          Expanded(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _segments,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '分段失败：${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }
                final segments = snapshot.data ?? const [];
                if (segments.isEmpty) {
                  return const Center(child: Text('本页没有可朗读的文字'));
                }
                return Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        itemCount: segments.length,
                        separatorBuilder: (_, _) => const Divider(height: 0.6),
                        itemBuilder: (context, index) {
                          final segment = segments[index];
                          final text = '${segment['text'] ?? ''}'.trim();
                          final paragraph = segment['paragraph'];
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 12,
                              backgroundColor: scheme.primaryContainer,
                              child: Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                            title: Text(
                              text,
                              style: const TextStyle(fontSize: 13),
                            ),
                            subtitle: paragraph == null
                                ? null
                                : Text(
                                    '第 $paragraph 段',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                          );
                        },
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                      color: scheme.surfaceContainerHighest.withValues(
                        alpha: 0.4,
                      ),
                      child: Text(
                        '音频引擎尚未接入，这里只展示 core 的分段结果（每段不超过 120 字）。',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
