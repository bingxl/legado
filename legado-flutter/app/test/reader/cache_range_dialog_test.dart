import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/widgets/cache_range_dialog.dart';

/// 阅读页手动缓存的范围弹层：默认当前章到末章，可改成任意起止章。
/// 章号对外是 1-based（与原版输入框一致），交给内核前统一转 0-based。
void main() {
  Future<void> openDialog(
    WidgetTester tester,
    void Function(Future<CacheRange?> Function()) launch,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => launch(
                  () => showCacheRangeDialog(
                    context: context,
                    currentChapter: 7,
                    totalChapters: 40,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('默认当前章到末章，确认后给出 0-based 下标', (tester) async {
    Future<CacheRange?>? pending;
    CacheRange? result;
    await openDialog(tester, (launch) {
      pending = launch();
      pending!.then((value) => result = value);
    });

    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '7');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '40');
    expect(find.textContaining('当前第 7 章 / 共 40 章'), findsOneWidget);

    await tester.tap(find.text('开始缓存'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    final range = result!;
    expect(range.start, 7);
    expect(range.end, 40);
    expect(range.indexes.first, 6);
    expect(range.indexes.last, 39);
    expect(range.count, 34);
  });

  testWidgets('起止章可改，转换后的下标闭区间不含卷外章节', (tester) async {
    Future<CacheRange?>? pending;
    CacheRange? result;
    await openDialog(tester, (launch) {
      pending = launch();
      pending!.then((value) => result = value);
    });

    await tester.enterText(find.byType(TextField).at(0), '3');
    await tester.enterText(find.byType(TextField).at(1), '5');
    await tester.tap(find.text('开始缓存'));
    await tester.pumpAndSettle();

    final range = result!;
    expect(range.start, 3);
    expect(range.end, 5);
    expect(range.indexes, <int>[2, 3, 4]);
  });

  testWidgets('起始大于结束时报错且不会开始缓存', (tester) async {
    Future<CacheRange?>? pending;
    CacheRange? result;
    await openDialog(tester, (launch) {
      pending = launch();
      pending!.then((value) => result = value);
    });

    await tester.enterText(find.byType(TextField).at(0), '9');
    await tester.enterText(find.byType(TextField).at(1), '4');
    await tester.tap(find.text('开始缓存'));
    await tester.pumpAndSettle();

    expect(find.text('起始章不能大于结束章'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField).at(1), '12');
    await tester.tap(find.text('开始缓存'));
    await tester.pumpAndSettle();
    expect(result!.indexes, <int>[8, 9, 10, 11]);
  });
}
