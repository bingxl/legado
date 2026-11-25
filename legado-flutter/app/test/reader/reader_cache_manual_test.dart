import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/reader/reader_page.dart';
import 'package:legado/features/reader/widgets/reader_menu.dart';
import 'package:legado/features/shelf/shelf_api.dart';

/// 阅读页「离线缓存」走真实内核：菜单弹层 → Cache.Start(chapters, indexes)。
/// 用本地 txt 书的 12 章目录，避免假 dto 掩盖 1-based → 0-based 的换算。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-reader-cache');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    // 后台缓存任务可能还握着 sqlite 文件句柄，删不掉就留给系统清理临时目录。
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on Object {
        // ignore
      }
    }
  });

  Future<void> settle(WidgetTester tester) async {
    // pumpAndSettle 会被阅读页的加载指示器/翻页动画卡住，固定帧推进更稳。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('阅读页菜单可改范围并启动缓存任务', (tester) async {
    int bookId = 0;
    await tester.runAsync(() async {
      final text = StringBuffer();
      // 正文写够长度：短中文样本会被编码探测误判成 GBK，分章直接塌成 1 章。
      const body = '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。'
          '他站在崖边，把信纸折了两折，塞进怀里，继续向前走去。';
      for (var i = 1; i <= 12; i++) {
        text.writeln('第$i章 测试章节');
        text.writeln(body);
        text.writeln();
      }
      final imported = await ShelfApi.importLocalBytes(
        [
          (
            name: '手动缓存.txt',
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
    int chapterCount = 0;
    await tester.runAsync(() async {
      chapterCount = (await LegadoClient.instance.callList(
        Api.readerGetChapters,
        [bookId],
      )).length;
    });
    expect(chapterCount, 12, reason: '本地 txt 必须解析出 12 章，才谈得上范围换算');

    await tester.pumpWidget(MaterialApp(home: ReaderPage(bookId: bookId)));
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 菜单平时是 IgnorePointer + opacity 0，widget 仍在树里；测试里直接调
    // 页面注入的回调，等价于点了菜单项，又不受加载态/翻页动画的点击拦截。
    final menu = tester.widget<ReaderMenuOverlay>(find.byType(ReaderMenuOverlay));
    expect(find.text('离线缓存'), findsOneWidget);
    menu.onCache();
    await settle(tester);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '1');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '12');

    // 把「当前章到末章」改成只缓存前三章。
    await tester.enterText(fields.at(1), '3');
    await tester.tap(find.text('开始缓存'));
    await settle(tester);

    List<Map<String, dynamic>> jobs = const [];
    await tester.runAsync(() async {
      jobs = await LegadoClient.instance.callList('Cache.Jobs');
    });
    final job = jobs.where((j) => (j['bookId'] as num?)?.toInt() == bookId);
    expect(job, isNotEmpty);
    expect(job.first['scope'], 'chapters');
    expect(job.first['total'], 3, reason: '1~3 章必须换算成 3 个 0-based 下标');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
