import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/reader/reader_page.dart';
import 'package:legado/features/reader/widgets/reader_menu.dart';
import 'package:legado/features/reader/widgets/reader_pager.dart';
import 'package:legado/features/reader/widgets/reader_scroll_view.dart';
import 'package:legado/features/settings/settings_api.dart';
import 'package:legado/features/settings/settings_store.dart';
import 'package:legado/features/shelf/shelf_api.dart';

/// 阅读区单击判定：上滑之后正文还在惯性滚动时轻触屏幕，只能让它停下，
/// 不能弹菜单（原版 `ReadView.abortAnim()` + `!isAbortAnim` 的语义）。
///
/// 这一组走真实内核（本地 txt 书），否则分页/滚动都是空的，
/// 「上滑」根本没有可滚的东西，测不出任何东西。
void main() {
  late Directory home;
  late int bookId;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-reader-tap');
    await LegadoClient.connect(homeDir: home.path);

    await _runAsyncRaw(() async {
      final text = StringBuffer();
      const body = '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。'
          '他站在崖边，把信纸折了两折，塞进怀里，继续向前走去。';
      for (var i = 1; i <= 4; i++) {
        text.writeln('第$i章 测试章节');
        for (var p = 0; p < 24; p++) {
          text.writeln(body);
        }
        text.writeln();
      }
      final imported = await ShelfApi.importLocalBytes(
        [
          (name: '手势测试.txt', bytes: utf8.encode(text.toString())),
        ],
        0,
        homeDir: home.path,
      );
      expect(imported['imported'], isNotEmpty);
      final books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
      bookId = (books.first['id'] as num).toInt();
    });
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on Object {
        // 内核可能还握着 sqlite 文件句柄，留给系统清理临时目录。
      }
    }
  });

  Future<void> openReader(WidgetTester tester, String pageTurn) async {
    await tester.runAsync(() async {
      await SettingsApi.updateValues({'reader.pageTurn': pageTurn});
      await SettingsStore.instance.load(force: true);
    });
    await tester.pumpWidget(MaterialApp(home: ReaderPage(bookId: bookId)));
    // 内核调用（读文件/建章节）要真实事件循环才会推进，假时钟里 pump 再多也不动；
    // 每次 runAsync 让出真实时间，再用 pump 收结果。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      final hasBody =
          find.byType(ReaderScrollView).evaluate().isNotEmpty ||
          find.byType(ReaderPager).evaluate().isNotEmpty;
      if (hasBody) break;
    }
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '正文必须加载完成，否则手势测试没有可点的区域',
    );
  }

  bool menuShown(WidgetTester tester) =>
      tester.widget<ReaderMenuOverlay>(find.byType(ReaderMenuOverlay)).visible;

  testWidgets('滚动模式：上滑后惯性滚动中轻触屏幕不弹菜单', (tester) async {
    await openReader(tester, 'scroll');
    expect(find.byType(ReaderScrollView), findsOneWidget);

    final center = tester.getCenter(find.byType(ReaderScrollView));

    // 基线：列表静止时点中间格要能正常呼出菜单。
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isTrue, reason: '静止时的单击必须照常弹菜单');
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isFalse);

    // 轻微上滑 12 逻辑像素：Flutter 的 kTouchSlop 是 18，仍会判成点击；
    // 原版容差是系统 8dp，这种抖动已经是「滑动」，不该弹菜单。
    await tester.drag(find.byType(ReaderScrollView), const Offset(0, -12));
    await tester.pump();
    expect(
      menuShown(tester),
      isFalse,
      reason: '超过 8dp 的手指移动算滑动，不是点击',
    );

    // 上滑 → 抬手后正文还在惯性滚动，此时轻触屏幕（想按住停住）。
    await tester.fling(
      find.byType(ReaderScrollView),
      const Offset(0, -240),
      1200,
    );
    await tester.tapAt(center);
    await tester.pump();


    expect(
      menuShown(tester),
      isFalse,
      reason: '中止惯性滚动的那一下只是「按住停住」，不能算点击',
    );

    // 等滚动彻底停下，再点一次：应当恢复成正常点击。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isTrue, reason: '滚动停下后的单击不能被误拦');
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('分页模式：翻页动画进行中点到中间格不弹菜单', (tester) async {
    await openReader(tester, 'cover');
    expect(find.byType(ReaderPager), findsOneWidget);

    final box = tester.getRect(find.byType(ReaderPager));
    final center = box.center;
    // 基线：静止时点中间格能弹菜单，翻页动画结束后也要能弹。
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isTrue);
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isFalse);
    // 右列 = 下一页，触发一次 240ms 的翻页动画。
    await tester.tapAt(Offset(box.right - 20, center.dy));
    await tester.pump(const Duration(milliseconds: 60));
    expect(menuShown(tester), isFalse);

    // 动画进行中点到中间格：等同于「按住打断动画」，不弹菜单。
    await tester.tapAt(center);
    await tester.pump();
    expect(
      menuShown(tester),
      isFalse,
      reason: '原版 onSingleTapUp 对中间格有 if (!isAbortAnim) 的门槛',
    );

    // 动画结束后的正常点击仍然弹菜单。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tapAt(center);
    await tester.pump();
    expect(menuShown(tester), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// setUpAll 里没有 WidgetTester，借用真实事件循环跑内核调用。
Future<void> _runAsyncRaw(Future<void> Function() body) async {
  // flutter_test 的 await 在 setUpAll 中仍跑在普通 Zone 里，直接 await 即可；
  // 单独包一层是为了让写法与 testWidgets 内的 runAsync 保持一致。
  await body();
}
