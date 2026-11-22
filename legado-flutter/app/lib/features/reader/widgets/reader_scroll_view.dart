import 'dart:async';

import 'package:flutter/material.dart';

import '../reader_controller.dart';
import '../reader_style.dart';
import '../tap_zone.dart';
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
    this.onBoundary,
  });

  final ReaderController controller;
  final ReaderStyle style;
  final bool menuVisible;
  final VoidCallback onTapCenter;

  /// 到第一章开头 / 最后一章末尾还继续拖时回调（1=向后，-1=向前）。
  final ValueChanged<int>? onBoundary;

  @override
  State<ReaderScrollView> createState() => ReaderScrollViewState();
}

class ReaderScrollViewState extends State<ReaderScrollView> {
  final ScrollController _scroll = ScrollController();

  late int _chapter = widget.controller.chapterIndex;
  late int _pageCount = widget.controller.pageCount;
  bool _jumping = false;
  bool _boundaryLock = false;

  /// 到底/到顶后继续拖拽的累计距离。超过阈值才换章：
  /// 轻微回弹、橡皮筋抖动不应该直接翻到下一章。
  double _overscroll = 0;
  static const double _overscrollThreshold = 56;

  /// 每页的实际高度。以 LayoutBuilder 给的为准，和 ListView 的 itemExtent 保持一致，
  /// 否则滚动偏移换算出的页码会错位（比如外层 inset 变化时）。
  double _pageExtent = 0;

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

  double get _extent =>
      _pageExtent > 0 ? _pageExtent : widget.controller.viewport.height;

  /// 只有「换章」或「重新分页」时才强制对齐，普通滚动不打断用户手势。
  void _syncFromController() {
    final controller = widget.controller;
    if (controller.chapterIndex == _chapter &&
        controller.pageCount == _pageCount) {
      return;
    }
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
    final index = (_scroll.offset / _extent).round().clamp(
      0,
      widget.controller.pageCount - 1,
    );
    widget.controller.noteScrollPage(index);
  }

  /// 跳到本章第 [index] 页（菜单进度条用）：改页码 + 立即对齐滚动位置。
  void jumpToPage(int index) {
    final controller = widget.controller;
    if (controller.pageCount == 0) return;
    final clamped = index.clamp(0, controller.pageCount - 1);
    controller.jumpToPage(clamped);
    _jumpTo(clamped);
  }

  /// 键盘/点击翻页：按一屏高度平滑滚动。
  Future<void> scrollByPage(int dir) async {
    if (!_scroll.hasClients || _extent <= 0) return;
    final target = (_scroll.offset + dir * _extent).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    // 到顶/到底再翻就换章，和分页模式的手感保持一致。
    final atEnd = _scroll.offset >= _scroll.position.maxScrollExtent - 1;
    final atStart = _scroll.offset <= 1;
    if ((dir > 0 && atEnd) || (dir < 0 && atStart)) {
      _crossBoundary(dir);
    }
  }

  void _swapChapter(Future<void> Function() action) {
    if (_boundaryLock) return;
    _boundaryLock = true;
    _overscroll = 0;
    unawaited(action());
    Timer(const Duration(milliseconds: 350), () => _boundaryLock = false);
  }

  /// 滚动模式也能「滚到底接着读下一章」：原版 `moveToNext` 就是这么做的。
  ///
  /// 我们的列表是本章的分页快照，滚到边界就停住了，没有可继续滚的内容，
  /// 只能靠 `OverscrollNotification` 判断「用户还在往同一方向拖」。
  /// 用 ClampingScrollPhysics，到边界后继续拖会稳定地产生这个通知。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is OverscrollNotification) {
      final delta = notification.overscroll;
      // 换方向就重新累计，避免来回蹭两下凑够阈值。
      if (_overscroll != 0 && delta.sign != _overscroll.sign) _overscroll = 0;
      _overscroll += delta;
      if (_overscroll >= _overscrollThreshold) {
        _crossBoundary(1);
      } else if (_overscroll <= -_overscrollThreshold) {
        _crossBoundary(-1);
      }
    } else if (notification is ScrollEndNotification) {
      _overscroll = 0;
    }
    return false;
  }

  void _crossBoundary(int dir) {
    if (_boundaryLock) return;
    final controller = widget.controller;
    if (controller.chapterLoading) return;
    final hasChapter = dir > 0
        ? controller.hasNextChapter
        : controller.hasPrevChapter;
    if (!hasChapter) {
      _overscroll = 0;
      // 边界提示也要节流：一次长拖会连发几十个 overscroll 通知。
      _boundaryLock = true;
      Timer(const Duration(milliseconds: 800), () => _boundaryLock = false);
      widget.onBoundary?.call(dir);
      return;
    }
    _swapChapter(dir > 0 ? controller.nextChapter : controller.prevChapter);
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
        if (extent != _pageExtent) {
          _pageExtent = extent;
          // 视口高度变化后页码对应的高度也变了，重新对齐当前页。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _jumpTo(controller.pageIndex);
          });
        }
        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              if (widget.menuVisible) {
                widget.onTapCenter();
                return;
              }
              // 与分页模式同一套 3×3 分区，滚动模式也不该「点中下部弹菜单」。
              final zone = readerTapZoneAt(
                details.localPosition,
                Size(constraints.maxWidth, constraints.maxHeight),
              );
              switch (zone) {
                case ReaderTapZone.prev:
                  scrollByPage(-1);
                case ReaderTapZone.next:
                  scrollByPage(1);
                case ReaderTapZone.menu:
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
          ),
        );
      },
    );
  }
}
