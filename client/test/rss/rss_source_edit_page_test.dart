import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/rss/rss_source_edit_page.dart';

/// 新建分支不依赖 core，可直接渲染与校验。
void main() {
  Future<void> pumpNew(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RssSourceEditPage()));
    await tester.pumpAndSettle();
  }

  Finder urlField() => find.byType(TextFormField).at(1);

  testWidgets('新增时展示空表单', (tester) async {
    await pumpNew(tester);
    expect(find.text('新增订阅源'), findsOneWidget);
    expect(find.text('订阅地址 *'), findsOneWidget);
    expect(find.text('启用'), findsOneWidget);
  });

  testWidgets('地址为空时被校验拦住', (tester) async {
    await pumpNew(tester);
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('订阅地址不能为空'), findsOneWidget);
  });

  testWidgets('非 http/https 地址被拒绝', (tester) async {
    await pumpNew(tester);
    await tester.enterText(urlField(), 'ftp://example.com/feed.xml');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('需要以 http:// 或 https:// 开头'), findsOneWidget);
  });
}
