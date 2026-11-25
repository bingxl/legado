import 'package:flutter/material.dart';

/// 文字目录与 PDF 分段目录共用的 BottomSheet 外壳。
///
/// 只负责标题栏、快捷滚动按钮与空态；每一项的视觉由 [itemBuilder] 决定
/// （文字目录有卷/付费/VIP 标记，PDF 目录显示页码区间，不能合并）。
class TocSheetScaffold extends StatefulWidget {
  const TocSheetScaffold({
    super.key,
    required this.countLabel,
    required this.itemCount,
    required this.itemBuilder,
    this.title = '目录',
    this.itemExtent,
    this.initialScrollOffset = 0,
  });

  final String title;
  final String countLabel;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;

  /// 传值时用固定行高，几千章的目录才能按 index 直接定位。
  final double? itemExtent;

  final double initialScrollOffset;

  @override
  State<TocSheetScaffold> createState() => _TocSheetScaffoldState();
}

class _TocSheetScaffoldState extends State<TocSheetScaffold> {
  late final ScrollController _scroll = ScrollController(
    initialScrollOffset: widget.initialScrollOffset,
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 动画而不是瞬移：长目录里用户需要看清经过的位置。
  void _scrollTo(double offset) {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      offset,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final empty = widget.itemCount == 0;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
            child: Row(
              children: [
                Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  widget.countLabel,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '回到开头',
                  icon: const Icon(Icons.vertical_align_top),
                  onPressed: empty ? null : () => _scrollTo(0),
                ),
                IconButton(
                  tooltip: '跳到最新',
                  icon: const Icon(Icons.vertical_align_bottom),
                  onPressed: empty ? null : () => _scrollTo(_scroll.position.maxScrollExtent),
                ),
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
            child: empty
                ? const Center(child: Text('暂无章节'))
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: widget.itemExtent,
                    itemCount: widget.itemCount,
                    itemBuilder: widget.itemBuilder,
                  ),
          ),
        ],
      ),
    );
  }
}
