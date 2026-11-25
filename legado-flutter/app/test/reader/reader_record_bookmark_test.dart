import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/reader/reader_page.dart';
import 'package:legado/features/reader/widgets/reader_menu.dart';
import 'package:legado/features/shelf/shelf_api.dart';
import 'package:legado/features/tools/tools_api.dart';

/// 阅读页「书签 / 阅读记录」此前是空壳：
/// - core 的 Bookmark.Add / Record.Append 都实现了却全仓零调用；
/// - 书签页空态提示「在阅读器点书签按钮」，而菜单里根本没有该按钮。
///
/// 这里在真实内核上验证 ToolsApi 的两个封装能落库（阅读器回调与菜单按钮
/// 分别通过 _recordRead / onBookmark 走这两个方法）；UI 按钮存在性由
/// reader_page_test 断言。widget test 的 fake-async 不推进 unawaited 的真实
/// IO，所以不在这里等 controller 自动写入。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-reader-record');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on Object {
        // ignore
      }
    }
  });

  Future<int> importBook() async {
    final text = StringBuffer();
    const body = '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。'
        '他站在崖边，把信纸折了两折，塞进怀里，继续向前走去。';
    for (var i = 1; i <= 5; i++) {
      text.writeln('第$i章 测试章节');
      text.writeln(body);
      text.writeln();
    }
    final imported = await ShelfApi.importLocalBytes(
      [
        (
          name: '记录书签.txt',
          bytes: utf8.encode(text.toString()),
        ),
      ],
      0,
      homeDir: home.path,
    );
    expect(imported['imported'], isNotEmpty);
    final books = await LegadoClient.instance.callList('Shelf.ListBooks', [0]);
    return (books.first['id'] as num).toInt();
  }

  testWidgets('阅读器菜单有书签入口，ToolsApi 封装能真实落库', (tester) async {
    late int bookId;
    await tester.runAsync(() async {
      bookId = await importBook();
    });
    expect(bookId, greaterThan(0));

    await tester.pumpWidget(MaterialApp(home: ReaderPage(bookId: bookId)));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('书签'), findsOneWidget);
    final menu = tester.widget<ReaderMenuOverlay>(find.byType(ReaderMenuOverlay));
    expect(menu.onBookmark, isNotNull);

    // 两个封装走的是阅读器回调实际调用的那两条 RPC：
    // _recordRead → recordAppend，_addBookmark → bookmarkAdd。
    await tester.runAsync(() async {
      await ToolsApi.recordAppend(
        bookId: bookId,
        bookName: '记录书签.txt',
        chapterIndex: 0,
        chapterTitle: '第1章 测试章节',
      );
      await ToolsApi.bookmarkAdd(
        bookId: bookId,
        chapterIndex: 0,
        chapterTitle: '第1章 测试章节',
      );
    });

    late List<Map<String, dynamic>> records;
    late List<Map<String, dynamic>> bookmarks;
    await tester.runAsync(() async {
      records = await LegadoClient.instance.callList('Record.List', [0, 50]);
      bookmarks = await LegadoClient.instance.callList('Bookmark.List', [0, 50]);
    });
    expect(records, isNotEmpty, reason: 'Record.Append 封装应落一条阅读记录');
    expect(
      (records.first['bookId'] as num?)?.toInt(),
      bookId,
      reason: '记录应属于当前书',
    );
    expect(bookmarks, isNotEmpty, reason: 'Bookmark.Add 封装应落一条书签');
    expect((bookmarks.first['bookId'] as num?)?.toInt(), bookId);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
