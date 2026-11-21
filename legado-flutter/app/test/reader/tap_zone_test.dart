import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/tap_zone.dart';

/// 阅读区点击分区：对齐原版 `AppConfig.clickAction*` 的 3×3 默认值。
void main() {
  const size = Size(300, 600);
  ReaderTapZone at(double x, double y) =>
      readerTapZoneAt(Offset(x, y), size);

  test('九宫格与原版默认点击动作一致', () {
    // 上排：左/中 = 上一页，右 = 下一页
    expect(at(10, 10), ReaderTapZone.prev);
    expect(at(150, 10), ReaderTapZone.prev);
    expect(at(290, 10), ReaderTapZone.next);
    // 中排：只有正中间是菜单
    expect(at(10, 300), ReaderTapZone.prev);
    expect(at(150, 300), ReaderTapZone.menu);
    expect(at(290, 300), ReaderTapZone.next);
    // 下排：左 = 上一页，中/右 = 下一页
    expect(at(10, 590), ReaderTapZone.prev);
    expect(at(150, 590), ReaderTapZone.next);
    expect(at(290, 590), ReaderTapZone.next);
  });

  test('中下部点击是下一页，不再误触菜单', () {
    // 单手拿手机时拇指常落在这里；以前中间整条竖带都弹菜单，
    // 用户会觉得「点哪都出菜单，进不了下一章」。
    expect(at(150, 500), ReaderTapZone.next);
    expect(at(140, 520), ReaderTapZone.next);
    expect(at(160, 420), ReaderTapZone.next);
  });

  test('三等分边界落在右/中列而不是左列', () {
    expect(at(100, 300), ReaderTapZone.menu); // x = w/3 → 中列
    expect(at(200, 300), ReaderTapZone.next); // x = 2w/3 → 右列
    expect(at(0, 0), ReaderTapZone.prev);
    expect(at(300, 600), ReaderTapZone.next);
  });

  test('视口为 0 时退回菜单，不抛除零', () {
    expect(readerTapZoneAt(Offset.zero, Size.zero), ReaderTapZone.menu);
    expect(readerTapZoneAt(const Offset(10, 10), const Size(0, 100)),
        ReaderTapZone.menu);
  });
}
