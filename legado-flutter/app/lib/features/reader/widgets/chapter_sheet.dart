import 'package:flutter/material.dart';

import '../reader_controller.dart';
import 'toc_sheet_scaffold.dart';

/// 目录 BottomSheet。
///
/// 用固定行高（48）而不是自适应高度：章节动辄几千条，固定 extent 让
/// ListView 能精确复用、也能直接按 `index * 48` 定位到当前章，不用先 build。
Future<void> showChapterSheet(
  BuildContext context,
  ReaderController controller,
) {
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

class _ChapterSheet extends StatelessWidget {
  const _ChapterSheet({required this.controller});

  final ReaderController controller;

  void _open(BuildContext context, int index) {
    Navigator.of(context).pop();
    controller.openChapter(index);
  }

  Widget _buildItem(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    final chapters = controller.chapters;
    final chapter = chapters[index];
    final current = index == controller.chapterIndex;
    final isVolume = chapter['isVolume'] == true;
    // 付费章 / VIP 章：书源写在 chapterList 的 `isPay` / `isVip`
    // 规则里，目录先标出来，免得点进去只看到空正文以为书源坏了。
    final isPay = chapter['isPay'] == true;
    final isVip = chapter['isVip'] == true;
    final title = '${chapter['title'] ?? ''}';
    return InkWell(
      onTap: isVolume ? null : () => _open(context, index),
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
                child: Icon(
                  Icons.folder_outlined,
                  size: 14,
                  color: scheme.outline,
                ),
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
            if (isPay)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: '付费章节',
                  child: Icon(
                    Icons.shopping_cart_outlined,
                    size: 14,
                    color: scheme.error,
                  ),
                ),
              )
            else if (isVip)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Tooltip(
                  message: 'VIP 章节',
                  child: Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: scheme.outline,
                  ),
                ),
              ),
            if (current)
              Icon(Icons.play_arrow, size: 16, color: scheme.primary),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chapters = controller.chapters;
    return TocSheetScaffold(
      countLabel: '共 ${chapters.length} 章',
      itemCount: chapters.length,
      itemExtent: 48,
      // 让当前章落在列表偏上，还能看到前后几章。
      initialScrollOffset: (controller.chapterIndex * 48 - 120 > 0
              ? controller.chapterIndex * 48 - 120
              : 0)
          .toDouble(),
      itemBuilder: _buildItem,
    );
  }
}
