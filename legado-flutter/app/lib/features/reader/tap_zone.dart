import 'dart:ui';

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
