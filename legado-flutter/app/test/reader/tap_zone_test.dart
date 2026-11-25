import 'dart:ui';

import 'package:flutter/gestures.dart';
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

  group('ReaderTapTracker（对齐原版 isMove / abortAnim）', () {
    PointerDownEvent down(int pointer, Offset at) =>
        PointerDownEvent(pointer: pointer, position: at);
    PointerMoveEvent move(int pointer, Offset at) =>
        PointerMoveEvent(pointer: pointer, position: at);

    void press(ReaderTapTracker t, Offset at, {bool busy = false, int pointer = 1}) {
      t.down(down(pointer, at), busy: busy);
    }

    test('容差是原版的 8dp，不是 Flutter 的 18', () {
      expect(readerTapSlop, 8);
    });

    test('没移动就是点击', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100));
      expect(t.confirm(), isTrue);
    });

    test('移动超过 8dp 就不再是点击（10dp 这种轻度抖动）', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100));
      t.move(move(1, const Offset(100, 90)));
      expect(t.busyDown, isFalse);
      expect(t.confirm(), isFalse);
    });

    test('移动未达容差仍算点击', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100));
      t.move(move(1, const Offset(102, 97)));
      expect(t.confirm(), isTrue);
    });

    test('按下时正在滚动 → busyDown，交给调用方决定怎么处理', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100), busy: true);
      expect(t.busyDown, isTrue);
      // 没有移动：手势本身成立，但业务上这是「按住停住滚动」。
      expect(t.confirm(), isTrue);
    });

    test('只滑动不点击的手势不能把后续点击废掉', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 300));
      t.move(move(1, const Offset(100, 200)));
      // 拖动由 ListView 消费，tap 回调不会来，confirm() 不会被调用。
      press(t, const Offset(100, 300));
      expect(t.confirm(), isTrue, reason: '上一次手势的状态必须被下一次按下覆盖');
    });

    test('一次手势只认一次点击，复位后重新计数', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100));
      expect(t.confirm(), isTrue);
      expect(t.confirm(), isFalse, reason: '同一次抬起不能被两层 detector 各算一次');
      press(t, const Offset(100, 100));
      expect(t.confirm(), isTrue);
    });

    test('取消手势后不再算点击', () {
      final t = ReaderTapTracker();
      press(t, const Offset(100, 100));
      t.cancel(
        PointerCancelEvent(pointer: 1, position: const Offset(100, 100)),
      );
      expect(t.confirm(), isFalse);
    });
  });
}
