import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/pagination.dart';
import 'package:legado/features/reader/reader_controller.dart';
import 'package:legado/features/reader/reader_page.dart';
import 'package:legado/features/reader/reader_style.dart';
import 'package:legado/features/reader/widgets/reader_menu.dart';
import 'package:legado/features/reader/widgets/reader_page_content.dart';

/// 这一组只验证「渲染层能吃下分页结果」，不触碰 core：
/// ReaderController 需要桥接，放到集成阶段；这里用纯分页结果直接喂 widget。
void main() {
  const style = ReaderStyle();
  const viewport = Size(360, 640);

  testWidgets('一页正文能正常渲染且不溢出', (tester) async {
    final pages = paginate(
      paragraphs: ['第一段正文内容，用来检查首行缩进与两端对齐。', '第二段正文内容，检查段间距。'],
      pageSize: style.contentSize(viewport),
      typography: style.typography,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: ReaderPageContent(
              page: pages.first,
              style: style,
              pageCount: pages.length,
              chapterTitle: '第一章 起风',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('第一段正文内容'), findsOneWidget);
    expect(find.text('1/${pages.length}'), findsOneWidget);
    expect(find.text('第一章 起风'), findsOneWidget);
  });

  testWidgets('正文比版心高时裁切而不是抛溢出错误', (tester) async {
    final pages = paginate(
      paragraphs: ['很长的一段话。' * 200],
      pageSize: style.contentSize(viewport),
      typography: style.typography,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: ReaderPageContent(
              page: pages.first,
              style: style,
              pageCount: pages.length,
              chapterTitle: '长段落',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  group('路由参数', () {
    test('缺省即续读', () {
      final page = ReaderPage.fromRouteArguments(null) as ReaderPage;
      expect(page.bookId, 0);
      expect(page.initialChapter, -1);
      expect(page.bookName, isNull);
    });

    test('解析书架的 arguments', () {
      final page =
          ReaderPage.fromRouteArguments({'bookId': 42, 'bookName': '剑来'})
              as ReaderPage;
      expect(page.bookId, 42);
      expect(page.bookName, '剑来');
      expect(page.initialChapter, -1);
    });
  });

  testWidgets('窄屏下菜单不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 不调用 load()：菜单纯渲染不依赖 core，构造 controller 只为拿默认状态。
    final controller = ReaderController(
      bookId: 1,
      initialChapter: -1,
      style: const ReaderStyle(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(color: Color(0xFFF6F1E1)),
              ),
              Positioned.fill(
                child: ReaderMenuOverlay(
                  controller: controller,
                  visible: true,
                  onClose: () {},
                  onOpenToc: () {},
                  onPrevChapter: () {},
                  onNextChapter: () {},
                  onStyleChanged: (_) {},
                  onSpeak: () {},
                  onRefresh: () {},
                  onSeek: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // 默认样式下底部栏的固定项应该在
    expect(find.text('朗读'), findsOneWidget);
    expect(find.text('上一章'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });

  group('ReaderStyle', () {
    test('版心扣除页边距与页脚', () {
      final size = style.contentSize(const Size(360, 640));
      expect(size.width, 360 - style.pagePadding.horizontal);
      expect(
        size.height,
        640 - style.pagePadding.vertical - ReaderStyle.footerHeight,
      );
    });

    test('字号变化会传递到排版参数与文本样式', () {
      final bigger = style.copyWith(fontSize: 28);
      expect(bigger.typography.fontSize, 28);
      expect(bigger.textStyle(Colors.black).fontSize, 28);
      // 不影响原对象
      expect(style.fontSize, 20);
    });
  });
}
