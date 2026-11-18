import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/tools/record_page.dart';

void main() {
  testWidgets('阅读记录页：core 未连接时显示错误态与重试', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecordPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('阅读记录'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('阅读天数'), findsNothing);
    expect(find.text('还没有阅读记录'), findsNothing);
  });

  testWidgets('阅读记录页：错误时仍保留清理入口', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RecordPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 清理入口不依赖列表是否加载成功：core 连上后重试即可用。
    expect(find.byTooltip('清理记录'), findsOneWidget);
  });
}
