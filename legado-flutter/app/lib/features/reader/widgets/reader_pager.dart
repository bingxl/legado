import 'package:flutter/material.dart';

import '../pagination.dart';
import '../reader_controller.dart';
import '../reader_style.dart';
import '../tap_zone.dart';
import 'reader_page_content.dart';

/// 分页翻页区（none / cover / slide / simulation）。
///
/// 自绘而不是 PageView：PageView 只能做 slide，覆盖动画需要「旧页不动、新页压过来」，
/// 而且翻到章末要切换整章数据，用 PageView 的 itemCount 很难表达。
/// 这里只在「章内相邻页」之间做动画，跨章交给 controller（加载态由父级显示）。
class ReaderPager extends StatefulWidget {
  const ReaderPager({
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

  /// 点击正中格（或菜单打开时任意点击）：呼出/关闭菜单。
  final VoidCallback onTapCenter;

  /// 翻到第一章/最后一章的边界还要继续翻时回调（1=向后，-1=向前）。
  /// 父级用来提示「已经是最后一章」，不然用户只看到点击没反应。
  final ValueChanged<int>? onBoundary;

  @override
  State<ReaderPager> createState() => ReaderPagerState();
}

class ReaderPagerState extends State<ReaderPager>
    with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 240);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: _duration,
  )..addStatusListener(_onStatus);

  int _dir = 1;
  PageSlice? _from;
  PageSlice? _to;
  bool _turning = false;
  double _dragDx = 0;

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final dir = _dir;
    _turning = false;
    _from = null;
    _to = null;
    _anim.reset();
    // 动画结束才真正提交页码，动画期间 controller.currentPage 仍是旧页，
    // 因此不用担心两套页码打架。
    widget.controller.turnPage(dir);
    if (mounted) setState(() {});
  }

  /// 供键盘/外部调用。
  void turn(int dir) => _begin(dir);

  void _begin(int dir) {
    if (_turning) return;
    final controller = widget.controller;
    if (controller.chapterLoading) return;
    final target = controller.neighborPage(dir);

    // 章末/章首：下一动作是换章（要等网络），期间必须锁住，
    // 否则快速连点两下会连续 nextChapter 跳过一章。
    if (target == null) {
      final hasChapter = dir > 0
          ? controller.hasNextChapter
          : controller.hasPrevChapter;
      if (!hasChapter) {
        // 全书边界：给提示，别让用户以为点坏了。
        widget.onBoundary?.call(dir);
        return;
      }
      _turning = true;
      controller.turnPage(dir).whenComplete(() {
        _turning = false;
        if (mounted) setState(() {});
      });
      return;
    }

    if (widget.style.pageTurn == PageTurnMode.none) {
      controller.turnPage(dir);
      return;
    }
    setState(() {
      _dir = dir;
      _turning = true;
      _from = controller.currentPage;
      _to = target;
    });
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final width = controller.viewport.width;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        if (widget.menuVisible) {
          widget.onTapCenter();
          return;
        }
        // 原版 3×3 分区：只有正中格是菜单，中上/中下也是翻页。
        final zone = readerTapZoneAt(
          details.localPosition,
          Size(width, controller.viewport.height),
        );
        switch (zone) {
          case ReaderTapZone.prev:
            _begin(-1);
          case ReaderTapZone.next:
            _begin(1);
          case ReaderTapZone.menu:
            widget.onTapCenter();
        }
      },
      // 滑动阈值触发：手指/鼠标横拖超过 40px 就翻页。
      // 不做实时跟手，是为了保证覆盖/滑动两种动画的边界行为一致。
      onHorizontalDragStart: widget.menuVisible ? null : (_) => _dragDx = 0,
      onHorizontalDragUpdate: widget.menuVisible
          ? null
          : (details) => _dragDx += details.delta.dx,
      onHorizontalDragEnd: widget.menuVisible
          ? null
          : (_) {
              if (_dragDx < -40) {
                _begin(1);
              } else if (_dragDx > 40) {
                _begin(-1);
              }
              _dragDx = 0;
            },
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _anim,
          builder: (context, _) {
            if (!_turning || _from == null || _to == null) {
              final page = controller.currentPage;
              if (page == null) return const SizedBox.shrink();
              return _page(page, 0);
            }
            return _animatedStack(width, _anim.value);
          },
        ),
      ),
    );
  }

  Widget _animatedStack(double width, double progress) {
    final from = _from!;
    final to = _to!;
    final slide = widget.style.pageTurn == PageTurnMode.slide;
    final List<Widget> layers;
    if (slide) {
      layers = _dir > 0
          ? [
              _page(from, -progress * width),
              _page(to, (1 - progress) * width, shadow: true),
            ]
          : [
              _page(to, -(1 - progress) * width, shadow: true),
              _page(from, progress * width),
            ];
    } else {
      // cover：旧页静止，新页从侧面盖上来。simulation 暂用同一路径近似，
      // 等有了更细的绘制管线再换成真正的仿真卷曲。
      layers = _dir > 0
          ? [_page(from, 0), _page(to, (1 - progress) * width, shadow: true)]
          : [_page(to, 0), _page(from, progress * width, shadow: true)];
    }
    return Stack(children: layers);
  }

  Widget _page(PageSlice page, double dx, {bool shadow = false}) {
    // 每页必须自带不透明底色：覆盖/滑动动画里两页会重叠，
    // 透明底会让旧页文字从新页下面透出来。
    Widget child = ColoredBox(
      color: widget.style.background.color,
      child: ReaderPageContent(
        page: page,
        style: widget.style,
        pageCount: widget.controller.pageCount,
        chapterTitle: widget.controller.chapterTitle,
      ),
    );
    if (shadow) {
      child = DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 14,
              offset: Offset(dx >= 0 ? -3 : 3, 0),
            ),
          ],
        ),
        child: child,
      );
    }
    return Transform.translate(offset: Offset(dx, 0), child: child);
  }
}
