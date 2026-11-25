import 'dart:ui';

import 'package:flutter/gestures.dart';

/// 阅读区的点击分区，对齐原版 `AppConfig.clickAction*` 的 3×3 默认布局：
///
/// ```
/// 上一页  上一页  下一页
/// 上一页  菜单    下一页
/// 上一页  下一页  下一页
/// ```
///
/// 和以前的实现差在哪：以前只要横坐标落在中间 1/3 就弹菜单（整条竖带），
/// 单手拿手机时拇指大多落在中下部——想翻页却呼出菜单，读起来就像
/// 「点不动、进不了下一章」。原版把中间列再切成三格，只有正中间那一格是菜单。
enum ReaderTapZone { prev, next, menu }

/// 按点击位置判定分区。[position] 是阅读区内的局部坐标。
ReaderTapZone readerTapZoneAt(Offset position, Size size) {
  if (size.width <= 0 || size.height <= 0) return ReaderTapZone.menu;
  final column = (position.dx / (size.width / 3)).floor().clamp(0, 2);
  final row = (position.dy / (size.height / 3)).floor().clamp(0, 2);

  // 左右两列整列翻页，中间列只有正中间是菜单。
  if (column == 0) return ReaderTapZone.prev;
  if (column == 2) return ReaderTapZone.next;
  return switch (row) {
    0 => ReaderTapZone.prev,
    1 => ReaderTapZone.menu,
    _ => ReaderTapZone.next,
  };
}

/// 点击容差（逻辑像素），对齐原版 `ViewConfiguration.get(context).scaledTouchSlop`
/// 的 8dp。
///
/// 为什么不用 Flutter 的 `kTouchSlop`：它是 18 逻辑像素，足足是原版的 2.25 倍。
/// 在 3 倍屏手机上，原版移动 24 物理像素就算「滑动」，而 Flutter 要 54 像素——
/// 手指上滑时轻微抖一下（十几像素）在原版是滑动，在这里却被判成点击，
/// 落在中间格就直接弹菜单。
const double readerTapSlop = 8;

/// 一次「按下 → 抬起」算不算单击，语义对齐原版 `ReadView.onTouchEvent`：
///
/// - 移动超过 [readerTapSlop] → `isMove`，不算点击；
/// - 按下时正文还在惯性滚动 / 翻页动画中 → [busyDown]，即原版
///   `ACTION_DOWN` 里的 `abortAnim()`：那一下只是「按住让它停下」。
///   各模式对它的处置不同（滚动模式整下作废，分页模式只挡中间格），
///   所以这里只提供标记，由调用方决定。
///
/// 用 `Listener` 驱动而不是 `GestureDetector` 的 `onTapDown/onTapUp`：
/// 正文插图自己有 detector，会抢走外层的 tap 回调，只有不参与手势竞技场的
/// `Listener` 才看得到每一次按下与移动。
///
/// 多指不在这里判断：Flutter 的 tap 识别器遇到第二根手指就会自己出局。
/// 自己数手指反而危险——漏掉一次抬起，后面所有点击都会被当成「多指」废掉。
class ReaderTapTracker {
  int? _pointer;
  Offset _down = Offset.zero;
  bool _moved = false;
  bool _busyDown = false;
  bool _consumed = false;

  /// 最近一次按下时是否在滚动/动画中（本手势是否「中止了动画」）。
  bool get busyDown => _busyDown;

  /// 每次按下都重新开始记录：上一次手势不管有没有被确认为点击，状态一律作废。
  void down(PointerDownEvent event, {required bool busy}) {
    _pointer = event.pointer;
    _down = event.position;
    _moved = false;
    _busyDown = busy;
    _consumed = false;
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != _pointer || _moved) return;
    if ((event.position - _down).distance > readerTapSlop) _moved = true;
  }

  void cancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _moved = true;
  }

  /// 抬起时判定一次「手指有没有动过」，同一次手势只认一次。
  bool confirm() {
    if (_consumed) return false;
    _consumed = true;
    return _pointer != null && !_moved;
  }
}
