import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/source/source_debug_page.dart';
import 'package:legado/features/source/source_list_page.dart';

/// bridge 未初始化时页面要落到错误态，而不是把 StateError 丢成红屏。
void main() {
  testWidgets('书源列表：未连接 core 时显示错误态与重试', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceListPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('书源管理'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('搜索名称 / 地址 / 分组'), findsOneWidget);
  });

  testWidgets('书源列表：新建菜单提供从文件导入', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceListPage()));
    await tester.pump();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('新建书源'), findsOneWidget);
    expect(find.text('粘贴 JSON 导入'), findsOneWidget);
    expect(find.text('从文件导入'), findsOneWidget);
    expect(find.text('从 URL 导入'), findsOneWidget);
  });

  testWidgets('书源列表：pickMode 只读标题', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: SourceListPage(pickMode: true)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('选择书源'), findsOneWidget);
    // 选择模式不出现新建入口。
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('书源调试：未连接 core 时给出错误提示', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceDebugPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('书源调试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
