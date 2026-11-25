import 'package:flutter/material.dart';

import '../../../core/widgets/copy_links.dart';
import '../progress.dart';
import '../reader_controller.dart';
import '../reader_style.dart';
import 'progress_slider.dart';

/// 阅读菜单覆盖层（顶部信息栏 + 底部操作栏）。
///
/// 用 `AnimatedOpacity` 而不是 `AnimatedSwitcher`：菜单关闭时保留 widget 树，
/// 打开时不会重新走一遍构建，翻页时也不会因为菜单显隐丢掉滚动位置。
class ReaderMenuOverlay extends StatefulWidget {
  const ReaderMenuOverlay({
    super.key,
    required this.controller,
    required this.visible,
    required this.onClose,
    required this.onOpenToc,
    required this.onPrevChapter,
    required this.onNextChapter,
    required this.onStyleChanged,
    required this.onSpeak,
    required this.onRefresh,
    required this.onCache,
    required this.onBookmark,
    required this.onSeek,
  });

  final ReaderController controller;
  final bool visible;

  /// 返回书架（先落盘进度）。
  final VoidCallback onClose;
  final VoidCallback onOpenToc;
  final VoidCallback onPrevChapter;
  final VoidCallback onNextChapter;
  final ValueChanged<ReaderStyle> onStyleChanged;
  final VoidCallback onSpeak;

  /// 强制重抓当前章（跳过离线缓存）。
  final VoidCallback onRefresh;

  /// 手动离线缓存：弹范围框后把选中章节交给内核 `Cache.Start`。
  final VoidCallback onCache;

  /// 在当前位置加书签（原版菜单「添加书签」）。
  final VoidCallback onBookmark;

  /// 本章进度 0~1，父级换算成章内页码跳转（对齐原版 `progressBarBehavior = "page"`）。
  final ValueChanged<double> onSeek;

  @override
  State<ReaderMenuOverlay> createState() => _ReaderMenuOverlayState();
}

class _ReaderMenuOverlayState extends State<ReaderMenuOverlay> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final style = controller.style;
    final background = style.background;
    final scheme = Theme.of(context).colorScheme;
    // 夜间背景用固定深色面板，避免 Material 主题的浅色 surface 在夜里刺眼。
    final panelColor = background.dark
        ? kReaderDarkPanel
        : scheme.surface.withValues(alpha: 0.97);
    final foreground = background.dark ? kReaderDarkForeground : scheme.onSurface;

    return IgnorePointer(
      ignoring: !widget.visible,
      child: AnimatedOpacity(
        opacity: widget.visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _topBar(panelColor, foreground),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _bottomBar(panelColor, foreground),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(Color panelColor, Color foreground) {
    final controller = widget.controller;
    return Material(
      color: panelColor,
      elevation: 1,
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            IconButton(
              tooltip: '返回',
              icon: Icon(Icons.arrow_back, color: foreground),
              onPressed: widget.onClose,
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.bookTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    controller.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '目录',
              icon: Icon(Icons.format_list_bulleted, color: foreground),
              onPressed: widget.onOpenToc,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(Color panelColor, Color foreground) {
    final controller = widget.controller;
    // 进度条统一是「本章」进度：文字章按分页，漫画章按图片张数
    // （原版 MangaMenu.upSeekBar(item.index, item.imageCount)），
    // 两者都不是全书跨度。
    final progress = controller.isManga
        ? ReaderProgress(index: controller.imageIndex, count: controller.imageCount)
        : ReaderProgress(index: controller.pageIndex, count: controller.pageCount);
    final pageLabel = progress.label;

    return Material(
      color: panelColor,
      elevation: 1,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: ReaderProgressSlider(
                      progress: progress,
                      themeData: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      enabled: progress.count > 0,
                      onSeek: widget.onSeek,
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      pageLabel,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        color: foreground.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  _chapterButton(
                    icon: Icons.skip_previous,
                    label: '上一章',
                    foreground: foreground,
                    // 用「可读章节」判断而不是裸下标：相邻若是卷标题，
                    // 禁用按钮比为难点的空跳更直观（与翻页区 onBoundary 一致）。
                    onPressed: controller.hasPrevChapter
                        ? widget.onPrevChapter
                        : null,
                  ),
                  Expanded(
                    child: Text(
                      controller.chapterLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: foreground.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  _chapterButton(
                    icon: Icons.skip_next,
                    label: '下一章',
                    foreground: foreground,
                    onPressed: controller.hasNextChapter
                        ? widget.onNextChapter
                        : null,
                  ),
                ],
              ),
              Divider(height: 12, color: foreground.withValues(alpha: 0.12)),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  _fontSizeGroup(foreground),
                  _turnModeChip(foreground),
                  _backgroundDots(foreground),
                  _actionChip(
                    foreground: foreground,
                    icon: Icons.record_voice_over_outlined,
                    label: '朗读',
                    onTap: widget.onSpeak,
                  ),
                  _actionChip(
                    foreground: foreground,
                    icon: Icons.refresh,
                    label: '刷新正文',
                    onTap: widget.onRefresh,
                  ),
                  _actionChip(
                    foreground: foreground,
                    icon: Icons.download_outlined,
                    label: '离线缓存',
                    onTap: widget.onCache,
                  ),
                  _actionChip(
                    foreground: foreground,
                    icon: Icons.bookmark_add_outlined,
                    label: '书签',
                    onTap: widget.onBookmark,
                  ),
                  _copyChip(foreground),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapterButton({
    required IconData icon,
    required String label,
    required Color foreground,
    required VoidCallback? onPressed,
  }) {
    return TextButton.icon(
      onPressed: onPressed,
      icon: Icon(
        icon,
        size: 18,
        color: foreground.withValues(alpha: onPressed == null ? 0.3 : 0.8),
      ),
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: foreground.withValues(alpha: onPressed == null ? 0.3 : 0.8),
        ),
      ),
    );
  }

  Widget _fontSizeGroup(Color foreground) {
    final style = widget.controller.style;
    final canShrink = style.fontSize > 12.5;
    final canGrow = style.fontSize < 35.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '减小字号',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.text_decrease,
            size: 20,
            color: foreground.withValues(alpha: canShrink ? 0.8 : 0.3),
          ),
          onPressed: canShrink
              ? () => widget.onStyleChanged(
                  style.copyWith(fontSize: style.fontSize - 2),
                )
              : null,
        ),
        Text(
          style.fontSize.toStringAsFixed(0),
          style: TextStyle(
            fontSize: 12,
            color: foreground.withValues(alpha: 0.7),
          ),
        ),
        IconButton(
          tooltip: '增大字号',
          visualDensity: VisualDensity.compact,
          icon: Icon(
            Icons.text_increase,
            size: 20,
            color: foreground.withValues(alpha: canGrow ? 0.8 : 0.3),
          ),
          onPressed: canGrow
              ? () => widget.onStyleChanged(
                  style.copyWith(fontSize: style.fontSize + 2),
                )
              : null,
        ),
      ],
    );
  }

  Widget _backgroundDots(Color foreground) {
    final style = widget.controller.style;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < ReaderBackground.presets.length; i++)
          Tooltip(
            message: ReaderBackground.presets[i].name,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () =>
                  widget.onStyleChanged(style.copyWith(backgroundIndex: i)),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: ReaderBackground.presets[i].color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: i == style.backgroundIndex
                        ? foreground.withValues(alpha: 0.85)
                        : foreground.withValues(alpha: 0.2),
                    width: i == style.backgroundIndex ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 翻页方式：做成 PopupMenuButton，点开直接选模式，比弹二级面板少一步。
  Widget _turnModeChip(Color foreground) {
    final style = widget.controller.style;
    return PopupMenuButton<PageTurnMode>(
      tooltip: '翻页方式',
      initialValue: style.pageTurn,
      onSelected: (mode) =>
          widget.onStyleChanged(style.copyWith(pageTurn: mode)),
      itemBuilder: (_) => PageTurnMode.values
          .map(
            (mode) => PopupMenuItem<PageTurnMode>(
              value: mode,
              child: Text(mode.label),
            ),
          )
          .toList(growable: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 20,
              color: foreground.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 2),
            Text(
              style.pageTurn.label,
              style: TextStyle(
                fontSize: 10,
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 底部操作项：图标 + 文字。
  Widget _actionChip({
    required Color foreground,
    required IconData icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: foreground.withValues(alpha: 0.8)),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 复制地址：菜单项按可用性生成（本地书没有书源地址等），点一项复制一项。
  ///
  /// 和 [_turnModeChip] 一样用 PopupMenuButton 而不是二级面板：
  /// 地址最多 3 条，一眼能选完。
  Widget _copyChip(Color foreground) {
    final controller = widget.controller;
    final links = bookCopyLinks(
      bookUrl: controller.bookUrl,
      chapterUrl: controller.chapterUrl,
    );
    final visual = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.link,
            size: 20,
            color: foreground.withValues(alpha: links.isEmpty ? 0.3 : 0.8),
          ),
          const SizedBox(height: 2),
          Text(
            '复制',
            style: TextStyle(
              fontSize: 10,
              color: foreground.withValues(alpha: links.isEmpty ? 0.3 : 0.75),
            ),
          ),
        ],
      ),
    );
    // 地址一个都没有（书不在书架、目录还没到）时不弹空菜单。
    if (links.isEmpty) return visual;
    return PopupMenuButton<int>(
      tooltip: '复制地址',
      onSelected: (index) => copyLink(context, links[index]),
      itemBuilder: (_) => [
        for (var i = 0; i < links.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.link, size: 20),
              title: Text('复制${links[i].label}'),
              subtitle: Text(
                links[i].value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
      ],
      child: visual,
    );
  }
}
