import 'package:flutter/material.dart';

import '../reader_controller.dart';
import '../reader_style.dart';

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

  /// 全书进度 0~1，父级换算成章节跳转。
  final ValueChanged<double> onSeek;

  @override
  State<ReaderMenuOverlay> createState() => _ReaderMenuOverlayState();
}

class _ReaderMenuOverlayState extends State<ReaderMenuOverlay> {
  /// 拖动进度条过程中的临时值：此时不立刻跳章，松手才跳。
  double? _seekValue;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final style = controller.style;
    final background = style.background;
    final scheme = Theme.of(context).colorScheme;
    // 夜间背景用固定深色面板，避免 Material 主题的浅色 surface 在夜里刺眼。
    final panelColor = background.dark
        ? const Color(0xFF262626)
        : scheme.surface.withValues(alpha: 0.97);
    final foreground = background.dark ? const Color(0xFFEDEDED) : scheme.onSurface;

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
                    style: TextStyle(color: foreground, fontSize: 15, fontWeight: FontWeight.w600),
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
    final percent = _seekValue ?? controller.bookPercent;

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
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                      ),
                      child: Slider(
                        value: percent.clamp(0.0, 1.0),
                        onChanged: (value) => setState(() => _seekValue = value),
                        onChangeEnd: (value) {
                          setState(() => _seekValue = null);
                          widget.onSeek(value);
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${(percent * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.7)),
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
                    onPressed: controller.chapterIndex > 0 ? widget.onPrevChapter : null,
                  ),
                  Expanded(
                    child: Text(
                      controller.chapterLabel,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.6)),
                    ),
                  ),
                  _chapterButton(
                    icon: Icons.skip_next,
                    label: '下一章',
                    foreground: foreground,
                    onPressed: controller.chapterIndex + 1 < controller.chapters.length
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
      icon: Icon(icon, size: 18, color: foreground.withValues(alpha: onPressed == null ? 0.3 : 0.8)),
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
          icon: Icon(Icons.text_decrease,
              size: 20, color: foreground.withValues(alpha: canShrink ? 0.8 : 0.3)),
          onPressed: canShrink
              ? () => widget.onStyleChanged(style.copyWith(fontSize: style.fontSize - 2))
              : null,
        ),
        Text(
          style.fontSize.toStringAsFixed(0),
          style: TextStyle(fontSize: 12, color: foreground.withValues(alpha: 0.7)),
        ),
        IconButton(
          tooltip: '增大字号',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.text_increase,
              size: 20, color: foreground.withValues(alpha: canGrow ? 0.8 : 0.3)),
          onPressed: canGrow
              ? () => widget.onStyleChanged(style.copyWith(fontSize: style.fontSize + 2))
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
              onTap: () => widget.onStyleChanged(style.copyWith(backgroundIndex: i)),
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
      onSelected: (mode) => widget.onStyleChanged(style.copyWith(pageTurn: mode)),
      itemBuilder: (_) => PageTurnMode.values
          .map((mode) => PopupMenuItem<PageTurnMode>(
                value: mode,
                child: Text(mode.label),
              ))
          .toList(growable: false),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_stories_outlined,
                size: 20, color: foreground.withValues(alpha: 0.8)),
            const SizedBox(height: 2),
            Text(
              style.pageTurn.label,
              style: TextStyle(fontSize: 10, color: foreground.withValues(alpha: 0.75)),
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
            Text(label, style: TextStyle(fontSize: 10, color: foreground.withValues(alpha: 0.75))),
          ],
        ),
      ),
    );
  }
}
