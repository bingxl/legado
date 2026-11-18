import 'dart:async';

import 'package:flutter/material.dart';

import '../reader_controller.dart';
import '../reader_style.dart';
import 'reader_page_content.dart';

/// 滚动模式：整章按页纵向排列，滚动位置换算成页码。
///
/// 为什么仍然按「页」而不是把整章文本丢进一个长列表：分页结果已经算好了，
/// 复用它可以保证滚动模式与翻页模式的断行、进度完全一致；
/// 每页高度固定为视口高度，滚动偏移除以页高就是页码，进度换算不需要额外状态。
class ReaderScrollView extends StatefulWidget {
  const ReaderScrollView({
    super.key,
    required this.controller,
    required this.style,
    required this.menuVisible,
    required this.onTapCenter,
  });

  final ReaderController controller;
  final ReaderStyle style;
  final bool menuVisible;
  final VoidCallback onTapCenter;

  @override
  State<ReaderScrollView> createState() => ReaderScrollViewState();
}

class ReaderScrollViewState extends State<ReaderScrollView> {
  final ScrollController _scroll = ScrollController();

  late int _chapter = widget.controller.chapterIndex;
  late int _pageCount = widget.controller.pageCount;
  bool _jumping = false;
  bool _boundaryLock = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncFromController);
    _scroll.addListener(_onScroll);
    // 首帧 ListView 还没有 position，等一帧再定位。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpTo(widget.controller.pageIndex);
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromController);
    _scroll.dispose();
    super.dispose();
  }

  double get _extent => widget.controller.viewport.height;

  /// 只有「换章」或「重新分页」时才强制对齐，普通滚动不打断用户手势。
  void _syncFromController() {
    final controller = widget.controller;
    if (controller.chapterIndex == _chapter && controller.pageCount == _pageCount) return;
    _chapter = controller.chapterIndex;
    _pageCount = controller.pageCount;
    // 必须等这一帧重建完再跳：新章页数可能比旧章多，
    // 立刻 jumpTo 会被旧的 maxScrollExtent 截断，停在上一章的位置。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpTo(controller.pageIndex);
    });
  }

  void _jumpTo(int pageIndex) {
    if (!_scroll.hasClients || _extent <= 0) return;
    final max = _scroll.position.maxScrollExtent;
    final target = (pageIndex * _extent).clamp(0.0, max);
    _jumping = true;
    _scroll.jumpTo(target);
    // jumpTo 会同步派发滚动通知，延后一帧再解锁，避免把程序滚动当成用户滚动。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumping = false;
    });
  }

  void _onScroll() {
    if (_jumping || !_scroll.hasClients || _extent <= 0) return;
    final index = (_scroll.offset / _extent).round().clamp(0, widget.controller.pageCount - 1);
    widget.controller.noteScrollPage(index);
  }

  /// 键盘/点击翻页：按一屏高度平滑滚动。
  Future<void> scrollByPage(int dir) async {
    if (!_scroll.hasClients || _extent <= 0) return;
    final target = (_scroll.offset + dir * _extent).clamp(0.0, _scroll.position.maxScrollExtent);
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    // 到顶/到底再翻就换章，和分页模式的手感保持一致。
    final atEnd = _scroll.offset >= _scroll.position.maxScrollExtent - 1;
    final atStart = _scroll.offset <= 1;
    if (dir > 0 && atEnd) {
      _swapChapter(widget.controller.nextChapter);
    } else if (dir < 0 && atStart) {
      _swapChapter(widget.controller.prevChapter);
    }
  }

  void _swapChapter(Future<void> Function() action) {
    if (_boundaryLock) return;
    _boundaryLock = true;
    unawaited(action());
    Timer(const Duration(milliseconds: 350), () => _boundaryLock = false);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent = constraints.maxHeight;
        if (controller.pages.isEmpty || extent <= 0) {
          return const SizedBox.shrink();
        }
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapUp: (details) {
            if (widget.menuVisible) {
              widget.onTapCenter();
              return;
            }
            final x = details.localPosition.dx;
            if (x < constraints.maxWidth / 3) {
              scrollByPage(-1);
            } else if (x > constraints.maxWidth * 2 / 3) {
              scrollByPage(1);
            } else {
              widget.onTapCenter();
            }
          },
          child: ListView.builder(
            controller: _scroll,
            itemExtent: extent,
            physics: const ClampingScrollPhysics(),
            itemCount: controller.pageCount,
            itemBuilder: (context, index) => ReaderPageContent(
              page: controller.pages[index],
              style: widget.style,
              pageCount: controller.pageCount,
              chapterTitle: controller.chapterTitle,
            ),
          ),
        );
      },
    );
  }
}
