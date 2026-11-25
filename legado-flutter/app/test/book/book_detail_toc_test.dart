import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/book/book_detail_page.dart';
import 'package:legado/features/shelf/shelf_api.dart';

/// 详情页「全部章节」弹层必须与阅读器目录一样提供到顶/到底快捷按钮。
/// 用真实内核导入一本多章本地书，避免造假 dto 掩盖字段差异。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-detail-toc');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  testWidgets('全部章节弹层提供回到开头 / 跳到最新', (tester) async {
    int bookId = 0;
    await tester.runAsync(() async {
      final text = StringBuffer();
      for (var i = 1; i <= 80; i++) {
        text.writeln('第$i章 测试章节\n正文内容。\n');
      }
      final imported = await ShelfApi.importLocalBytes(
        [
          (
            name: '目录快捷跳转.txt',
            bytes: utf8.encode(text.toString()),
          ),
        ],
        0,
        homeDir: home.path,
      );
      expect(imported['imported'], isNotEmpty);
      final books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
      bookId = (books.first['id'] as num).toInt();
    });
    expect(bookId, greaterThan(0));

    await tester.pumpWidget(MaterialApp(home: BookDetailPage(bookId: bookId)));
    // 详情页首屏走真实 sqlite IO；fake-async zone 里用固定帧推进。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.widgetWithText(TextButton, '全部章节'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byTooltip('回到开头'), findsOneWidget);
    expect(find.byTooltip('跳到最新'), findsOneWidget);

    // 两个按钮都能点击且不抛异常；动画由 TocSheetScaffold 内部驱动。
    await tester.tap(find.byTooltip('跳到最新'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('回到开头'));
    await tester.pump(const Duration(milliseconds: 400));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
