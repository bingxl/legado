import 'package:flutter/widgets.dart';

/// 把「到边界后继续拖」的 OverscrollNotification 累计成换章方向。
///
/// 滚动正文与漫画视图各有一份逐行相同的实现，差别只在阈值/锁时长；
/// 这里只抽通知解析与累计，换章节流仍留给各视图自己处理。
class OverscrollAccumulator {
  OverscrollAccumulator({this.threshold = 56});

  final double threshold;
  double _value = 0;

  void reset() => _value = 0;

  /// 返回 0 表示不换章，+1 下一章，-1 上一章。
  int accept(ScrollNotification notification) {
    if (notification.depth != 0) return 0;
    if (notification is OverscrollNotification) {
      final delta = notification.overscroll;
      // 换方向就重新累计，避免来回蹭两下凑够阈值。
      if (_value != 0 && delta.sign != _value.sign) _value = 0;
      _value += delta;
      if (_value >= threshold) {
        reset();
        return 1;
      }
      if (_value <= -threshold) {
        reset();
        return -1;
      }
    } else if (notification is ScrollEndNotification) {
      reset();
    }
    return 0;
  }
}
