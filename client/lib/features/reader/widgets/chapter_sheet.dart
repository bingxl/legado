import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../reader_controller.dart';

/// 目录 BottomSheet。
///
/// 用固定行高（48）而不是自适应高度：章节动辄几千条，固定 extent 让
/// ListView 能精确复用、也能直接按 `index * 48` 定位到当前章，不用先 build。
Future<void> showChapterSheet(BuildContext context, ReaderController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ChapterSheet(controller: controller),
  );
}

class _ChapterSheet extends StatefulWidget {
  const _ChapterSheet({required this.controller});

  final ReaderController controller;

  @override
  State<_ChapterSheet> createState() => _ChapterSheetState();
}

class _ChapterSheetState extends State<_ChapterSheet> {
  static const double _itemExtent = 48;

  late final ScrollController _scroll = ScrollController(
    // 让当前章落在列表偏上的位置，用户还能看到前后几章。
    initialScrollOffset: math.max(0, widget.controller.chapterIndex * _itemExtent - 120),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _open(int index) {
    Navigator.of(context).pop();
    widget.controller.openChapter(index);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    final chapters = controller.chapters;

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text('目录', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '共 ${chapters.length} 章',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '关闭',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 0.6),
          Expanded(
            child: chapters.isEmpty
                ? const Center(child: Text('暂无章节'))
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: _itemExtent,
                    itemCount: chapters.length,
                    itemBuilder: (context, index) {
                      final chapter = chapters[index];
                      final current = index == controller.chapterIndex;
                      final isVolume = chapter['isVolume'] == true;
                      final title = '${chapter['title'] ?? ''}';
                      return InkWell(
                        onTap: () => _open(index),
                        child: Container(
                          color: current ? scheme.primary.withValues(alpha: 0.08) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 44,
                                child: Text(
                                  '${index + 1}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: current ? scheme.primary : scheme.outline,
                                  ),
                                ),
                              ),
                              if (isVolume)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Icon(Icons.folder_outlined,
                                      size: 14, color: scheme.outline),
                                ),
                              Expanded(
                                child: Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: current ? FontWeight.w600 : FontWeight.w400,
                                    color: current ? scheme.primary : scheme.onSurface,
                                  ),
                                ),
                              ),
                              if (current)
                                Icon(Icons.play_arrow, size: 16, color: scheme.primary),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
