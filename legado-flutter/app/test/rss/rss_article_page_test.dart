import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/rss/rss_article_page.dart';

/// 正文页不依赖 bridge 就能渲染；markRead 失败被静默处理。
void main() {
  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  testWidgets('渲染标题、来源、时间与正文', (tester) async {
    await pumpPage(
      tester,
      RssArticlePage(
        articleId: 1,
        title: '一篇文章',
        content: '<p>第一段</p><p>第二段</p>',
        link: 'https://example.com/a',
        pubDate: DateTime(2024, 5, 6, 7, 8).millisecondsSinceEpoch ~/ 1000,
        sourceName: '示例源',
      ),
    );

    expect(find.text('一篇文章'), findsOneWidget);
    expect(find.textContaining('示例源'), findsOneWidget);
    expect(find.textContaining('2024-05-06 07:08'), findsOneWidget);
    expect(find.text('第一段\n\n第二段'), findsOneWidget);
  });

  testWidgets('没有正文时给空态提示', (tester) async {
    await pumpPage(
      tester,
      const RssArticlePage(articleId: 2, title: '无正文'),
    );

    expect(find.text('这篇文章没有正文'), findsOneWidget);
    // 无链接时不出现复制入口。
    expect(find.text('复制原文链接'), findsNothing);
  });

  testWidgets('字号可以加减并夹在上下限内', (tester) async {
    await pumpPage(
      tester,
      const RssArticlePage(articleId: 3, title: '字号', content: '正文'),
    );

    expect(find.text('17'), findsOneWidget);
    await tester.tap(find.byTooltip('放大字号'));
    await tester.pump();
    expect(find.text('18'), findsOneWidget);

    await tester.tap(find.byTooltip('缩小字号'));
    await tester.pump();
    expect(find.text('17'), findsOneWidget);

    // 连续缩小到下限后按钮禁用。
    final decrease = find.widgetWithIcon(IconButton, Icons.text_decrease);
    for (var i = 0; i < 10; i++) {
      if (tester.widget<IconButton>(decrease).onPressed == null) break;
      await tester.tap(decrease);
      await tester.pump();
    }
    expect(find.text('13'), findsOneWidget);
  });

  testWidgets('未收藏时显示空心星标', (tester) async {
    await pumpPage(
      tester,
      const RssArticlePage(articleId: 4, title: '收藏', content: '正文'),
    );

    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(find.byIcon(Icons.star), findsNothing);
  });

  testWidgets('已收藏时显示实心星标', (tester) async {
    await pumpPage(
      tester,
      const RssArticlePage(
        articleId: 5,
        title: '收藏',
        content: '正文',
        favorite: true,
      ),
    );

    expect(find.byIcon(Icons.star), findsOneWidget);
  });
}
