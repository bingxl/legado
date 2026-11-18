import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/tools/cache_page.dart';

void main() {
  testWidgets('缓存页：core 未连接时显示错误态与重试，不显示统计条', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CachePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 拿不到统计就不该出现「0 本书 0 章」这种假数据。
    expect(find.text('本书'), findsNothing);
    expect(find.byTooltip('全部清空'), findsOneWidget);
  });

  testWidgets('缓存页：错误信息可读且刷新按钮存在', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CachePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // bridge 未初始化时抛 StateError，兜底文案里要带上原因，不能只剩空串。
    expect(find.textContaining('bridge 尚未初始化'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget);
  });
}
