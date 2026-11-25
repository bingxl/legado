import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/progress.dart';
import 'package:legado/features/reader/widgets/progress_slider.dart';

/// 共享进度条：拖动过程中不跳页，松手才回调（对齐原版 onStopTrackingTouch）。
void main() {
  testWidgets('拖动中不回调，松手才按百分比跳', (tester) async {
    final seeks = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: ReaderProgressSlider(
                progress: const ReaderProgress(index: 2, count: 9),
                onSeek: seeks.add,
              ),
            ),
          ),
        ),
      ),
    );

    final slider = find.byType(Slider);
    expect(slider, findsOneWidget);
    expect(seeks, isEmpty);

    // 只按下并移动：还没有抬起，不应触发跳转。
    final center = tester.getCenter(slider);
    final drag = await tester.startGesture(center);
    await drag.moveBy(const Offset(100, 0));
    await tester.pump();
    expect(seeks, isEmpty, reason: '拖动中不能每帧跳页');

    await drag.up();
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(0.5));
  });

  testWidgets('没有可跳项时禁用', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderProgressSlider(
            progress: const ReaderProgress(index: 0, count: 0),
            onSeek: (_) => fail('不该回调'),
          ),
        ),
      ),
    );
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
  });
}
