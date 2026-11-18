import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/rss/rss_home_page.dart';
import 'package:legado/features/rss/rss_source_tab.dart';

/// bridge 未初始化时（测试环境即如此），页面要落到错误态而不是红屏。
void main() {
  testWidgets('订阅首页：两个 tab 与源加载失败提示', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RssHomePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('订阅'), findsOneWidget);
    expect(find.text('文章'), findsOneWidget);
    expect(find.text('订阅源'), findsOneWidget);
    expect(find.textContaining('订阅源加载失败'), findsOneWidget);
    // 文章 tab 自身也落到错误态，且有重试入口。
    expect(find.text('重试'), findsWidgets);
    // 文章 tab 上不显示新增订阅源的 FAB。
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('订阅首页：切到订阅源 tab 显示新增 FAB', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RssHomePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('订阅源'));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.text('还没有订阅源，点右下角新增'), findsOneWidget);
  });

  testWidgets('订阅源 tab：空态提示新增', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RssSourceTab(
            sources: const [],
            onChanged: () async {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('还没有订阅源，点右下角新增'), findsOneWidget);
  });

  testWidgets('订阅源 tab：渲染名称、未读数与停用标记', (tester) async {
    final sources = <Map<String, dynamic>>[
      {
        'id': 1,
        'name': '示例源',
        'url': 'https://example.com/feed.xml',
        'group': '科技',
        'enabled': true,
        'unreadCount': 5,
      },
      {
        'id': 2,
        'name': '停用源',
        'url': 'https://b.example.com/rss',
        'group': '',
        'enabled': false,
        'unreadCount': 0,
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RssSourceTab(sources: sources, onChanged: () async {}),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('示例源'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('科技 · https://example.com/feed.xml'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
  });
}
