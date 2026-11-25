import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/progress.dart';

/// 三套阅读器共用的进度条口径：首项 0%、末项 100%，与章节/全书跨度无关。
void main() {
  test('章内进度首项 0、末项 1', () {
    expect(readPercentForIndex(0, 12), 0);
    expect(readPercentForIndex(11, 12), 1);
    expect(readPercentForIndex(5, 11), 0.5);
  });

  test('只有一项时进度为 1，且逆换算不越界', () {
    expect(readPercentForIndex(0, 1), 1);
    expect(indexForReadPercent(1, 1), 0);
    expect(indexForReadPercent(0.5, 1), 0);
  });

  test('百分比逆换算与正换算互逆', () {
    for (final count in [2, 3, 10, 50]) {
      for (var i = 0; i < count; i++) {
        expect(indexForReadPercent(readPercentForIndex(i, count), count), i,
            reason: 'count=$count index=$i');
      }
    }
  });

  test('空项与越界输入被夹紧，不抛异常', () {
    expect(readPercentForIndex(0, 0), 0);
    expect(indexForReadPercent(0.7, 0), 0);
    expect(readPercentForIndex(99, 3), 1);
    expect(indexForReadPercent(5, 3), 2);
  });

  test('ReaderProgress 标签是章内页码', () {
    expect(const ReaderProgress(index: 0, count: 8).label, '1/8');
    expect(const ReaderProgress(index: 7, count: 8).label, '8/8');
    expect(const ReaderProgress(index: 3, count: 0).label, '--');
  });
}
