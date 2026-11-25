import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/core/shelf_events.dart';
import 'package:legado/features/book/book_detail_page.dart';
import 'package:legado/features/shelf/shelf_api.dart';
import 'package:legado/features/shelf/shelf_page.dart';

/// 书架同步：原版书架是 Room + Flow（表变列表自动刷新），Flutter 侧靠
/// [ShelfEvents] 广播。这里用真实内核 + 临时 home 验证两条链路：
/// 1. 详情页在架时按钮变成「移出书架」，确认后真的删书；
/// 2. 书架页收到广播后会自己重拉，不需要下拉刷新或重启。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-shelf-sync');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  /// 推进若干帧让真实 sqlite/RPC 的 Future 落地（fake-async 不推进真实 IO）。
  Future<void> settle(WidgetTester tester, [int frames = 12]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// 导入一本本地书并返回它的 id。
  ///
  /// 文件名用短 ASCII：书名由文件名推出，这里只要一个可区分的标记，
  /// 中文名的保留由 `import_name_test.dart` 单独覆盖。
  Future<int> importBook(WidgetTester tester, String marker) async {
    var bookId = 0;
    await tester.runAsync(() async {
      final before = (await LegadoClient.instance.callList(Api.shelfListBooks, [0]))
          .map((b) => (b['id'] as num).toInt())
          .toSet();
      final text = StringBuffer()
        ..writeln('第1章 开端')
        ..writeln('正文内容。')
        ..writeln();
      final imported = await ShelfApi.importLocalBytes(
        [
          (name: '$marker.txt', bytes: utf8.encode(text.toString())),
        ],
        0,
        homeDir: home.path,
      );
      expect(imported['imported'], isNotEmpty);
      final books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
      bookId = (books
              .firstWhere(
                (b) => !before.contains((b['id'] as num).toInt()),
              )['id'] as num)
          .toInt();
    });
    return bookId;
  }

  testWidgets('详情页在架时显示「移出书架」，确认后删书并广播', (tester) async {
    final bookId = await importBook(tester, 'syncA');
    expect(bookId, greaterThan(0));
    final before = ShelfEvents.revision.value;

    // 放在二级路由上，模拟从书架/搜索进入详情页，删除后能正常返回。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BookDetailPage(bookId: bookId),
                ),
              ),
              child: const Text('打开详情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开详情'));
    await settle(tester);

    // 已在书架：按钮是「移出书架」而不是灰掉的「已在书架」。
    expect(find.text('移出书架'), findsOneWidget);
    expect(find.text('已在书架'), findsNothing);

    await tester.tap(find.text('移出书架'));
    await settle(tester, 6);
    expect(find.text('是否确认删除？'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await settle(tester, 10);

    // 广播发出去了，书架页才有机会刷新。
    expect(ShelfEvents.revision.value, greaterThan(before));

    // 真的从库里删掉了（连目录/进度/缓存一起清）。
    await tester.runAsync(() async {
      final books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
      expect(books.any((b) => (b['id'] as num).toInt() == bookId), isFalse);
    });

    // 原版 deleteBook 成功后 finish()，这里对应 pop 回上一页。
    expect(find.text('打开详情'), findsOneWidget);
    expect(find.text('移出书架'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('书架页收到广播后自动重拉，无需手动刷新', (tester) async {
    final bookId = await importBook(tester, 'syncB');

    await tester.pumpWidget(const MaterialApp(home: ShelfPage()));
    await settle(tester);
    expect(find.textContaining('syncB'), findsOneWidget);

    // 模拟别处（详情页/阅读器）删书：只调 core + 广播，不动书架页本身。
    await tester.runAsync(() async {
      await ShelfApi.deleteBooks([bookId]);
    });
    ShelfEvents.changed();
    await settle(tester);

    expect(find.textContaining('syncB'), findsNothing);
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('新书入库后书架页自动出现，无需重进页面', (tester) async {
    await importBook(tester, 'syncC');

    await tester.pumpWidget(const MaterialApp(home: ShelfPage()));
    await settle(tester);
    expect(find.textContaining('syncC'), findsOneWidget);
    expect(find.textContaining('syncD'), findsNothing);

    // 模拟「详情页加入书架 / 导入」后再广播：书架页应自己重拉。
    await importBook(tester, 'syncD');
    ShelfEvents.changed();
    await settle(tester);

    expect(find.textContaining('syncD'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
