import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/me/me_page.dart';

void main() {
  testWidgets('我的页：core 未连接时入口仍可用，统计整行隐藏', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: MePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('我的'), findsOneWidget);
    // 版本取不到时显示「未知」，而不是空白或 0。
    expect(find.text('版本 未知'), findsOneWidget);

    // 三个分组的首项都应在首屏可见。
    expect(find.text('书源管理'), findsOneWidget);
    expect(find.text('替换净化'), findsOneWidget);
    expect(find.text('订阅源'), findsOneWidget);

    // 统计行取不到就整行隐藏，避免显示 0 误导。
    expect(find.text('缓存章节'), findsNothing);
  });

  testWidgets('我的页：点击入口跳到对应具名路由', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: const MePage(),
        routes: {'/tools/bookmark': (_) => const Scaffold(body: Text('书签页占位'))},
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final entry = find.text('书签');
    await tester.ensureVisible(entry);
    await tester.pump();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('书签页占位'), findsOneWidget);
  });
}
