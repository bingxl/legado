import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/tools/bookmark_page.dart';

void main() {
  testWidgets('书签页：core 未连接时显示错误态与重试', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BookmarkPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('书签'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    // 出错时不显示空态文案，否则用户会以为书签被清空了。
    expect(find.text('还没有书签'), findsNothing);
  });

  testWidgets('书签页：加载失败提示里带出具体原因', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: BookmarkPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('bridge 尚未初始化'), findsOneWidget);
  });
}
