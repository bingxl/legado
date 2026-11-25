import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/widgets/cached_reader_image.dart';
import '../reader_controller.dart';
import '../reader_style.dart';
import '../tap_zone.dart';
import 'overscroll_accumulator.dart';
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
    this.onImageDoubleTap,
    this.localImagePath,
  });

  final ReaderController controller;
  final ReaderStyle style;
  final bool menuVisible;
  final VoidCallback onTapCenter;

  /// 到第一章开头 / 最后一章末尾还继续拖时回调（1=向后，-1=向前）。
  final ValueChanged<int>? onBoundary;

  /// 双击正文插图：打开全屏看图。
  final ValueChanged<String>? onImageDoubleTap;

  /// 插图本地缓存路径查询（ReaderController.imagePathOf）。
  final LocalImagePathResolver? localImagePath;

  @override
  State<ReaderScrollView> createState() => ReaderScrollViewState();
}

class ReaderScrollViewState extends State<ReaderScrollView> {
  final ScrollController _scroll = ScrollController();

  late int _chapter = widget.controller.chapterIndex;
  late int _pageCount = widget.controller.pageCount;
  bool _jumping = false;
  bool _boundaryLock = false;

  /// 点击判定（见 [ReaderTapTracker]）：移动超容差、或按下时还在滚动都不算点击。
  final ReaderTapTracker _tap = ReaderTapTracker();

  /// 正文刚刚还在滚动（拖动 / 惯性 / 点击翻页的动画）。
  ///
  /// 为什么不能只看 `isScrollingNotifier`：手指一按下，Scrollable 就把弹道滚动
  /// 换成 hold，`isScrollingNotifier` 立刻变 false——等到判定时已经看不出来了。
  /// 所以反过来记「最近有没有滚动过」，150ms 内都算「还在滚」。
  bool _gliding = false;
  Timer? _glideTimer;

  /// 原版 `ReadView.abortAnim()` 的等价物：这一下按下中止了滚动，
  /// 只是「按住让它停下」，绝不能当成点击（否则中间格直接弹菜单）。
  bool get _busyAtDown => _gliding;

  /// 到底/到顶后继续拖拽的累计距离。超过阈值才换章：
  /// 轻微回弹、橡皮筋抖动不应该直接翻到下一章。
  final OverscrollAccumulator _overscroll = OverscrollAccumulator();

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
    _glideTimer?.cancel();
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
    _overscroll.reset();
    unawaited(action());
    Timer(const Duration(milliseconds: 350), () => _boundaryLock = false);
  }

  /// 滚动模式也能「滚到底接着读下一章」：原版 `moveToNext` 就是这么做的。
  ///
  /// 我们的列表是本章的分页快照，滚到边界就停住了，没有可继续滚的内容，
  /// 只能靠 `OverscrollNotification` 判断「用户还在往同一方向拖」。
  /// 用 ClampingScrollPhysics，到边界后继续拖会稳定地产生这个通知。
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth == 0) _markGliding();
    final dir = _overscroll.accept(notification);
    if (dir != 0) _crossBoundary(dir);
    return false;
  }

  /// 记一次「刚滚动过」。滚动通知在拖动/惯性/动画期间是每帧一条，
  /// 所以持续滚动时这个标记会一直续期，停下 150ms 后才失效。
  void _markGliding() {
    _gliding = true;
    _glideTimer?.cancel();
    _glideTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _gliding = false;
    });
  }

  void _crossBoundary(int dir) {
    if (_boundaryLock) return;
    final controller = widget.controller;
    if (controller.chapterLoading) return;
    final hasChapter = dir > 0
        ? controller.hasNextChapter
        : controller.hasPrevChapter;
    if (!hasChapter) {
      _overscroll.reset();
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
        void handleTap(Offset local) {
          if (widget.menuVisible) {
            widget.onTapCenter();
            return;
          }
          // 与分页模式同一套 3×3 分区，滚动模式也不该「点中下部弹菜单」。
          final zone = readerTapZoneAt(
            local,
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
        }

        /// 一次点击的入口：先过 [ReaderTapTracker]，再区分「只是按停滚动」。
        ///
        /// 原版 `ScrollPageDelegate` 里，点击翻页和中间格弹菜单都以
        /// `isAbortAnim` 为前提：手指按下时正文还在惯性滚动，这一下只负责
        /// 让滚动停下，什么也不做。少了这道判断，上滑后想把内容按住，
        /// 手指一碰屏幕就弹菜单。
        void maybeTap(Offset local) {
          final abortedGlide = _tap.busyDown;
          if (!_tap.confirm()) return;
          if (abortedGlide) return;
          handleTap(local);
        }

        return NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: Listener(
            // Listener 不进手势竞技场，只旁观：正文插图自己的 detector
            // 抢走 tap 时也能拿到同一份按下/移动数据。
            behavior: HitTestBehavior.translucent,
            onPointerDown: (event) => _tap.down(event, busy: _busyAtDown),
            onPointerMove: _tap.move,
            onPointerCancel: _tap.cancel,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (details) => maybeTap(details.localPosition),
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
                  // 插图单击：透传全局坐标，换算后复用同一套分区翻页。
                  onImageTapUp: (global) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null || !box.hasSize) return;
                    maybeTap(box.globalToLocal(global));
                  },
                  onImageDoubleTap: widget.onImageDoubleTap,
                  localImagePath: widget.localImagePath,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
