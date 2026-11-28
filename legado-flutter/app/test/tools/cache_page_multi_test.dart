import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/shelf/shelf_api.dart';
import 'package:legado/features/tools/cache_page.dart';
import 'package:legado/features/tools/tools_api.dart';

/// 缓存管理页多选：走真实内核（本地 txt），验证批量清除与章节批量删除。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-cache-multi');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) {
      try {
        home.deleteSync(recursive: true);
      } on Object {
        // 后台任务可能还握着 sqlite 文件句柄，留给系统清理。
      }
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 导入本地书并缓存前两章；所有真实 I/O 必须在 runAsync 里跑。
  Future<List<int>> importAndCacheBooks(WidgetTester tester, int count) async {
    final ids = await tester.runAsync(() async {
      final result = <int>[];
      for (var n = 1; n <= count; n++) {
        final text = StringBuffer();
        const body = '　　天色渐暗，风从山脊上压下来，吹得满林的松针一起响。'
            '他站在崖边，把信纸折了两折，塞进怀里，继续向前走去。';
        for (var i = 1; i <= 4; i++) {
          text.writeln('第$i章 测试章节$n');
          text.writeln(body);
          text.writeln();
        }
        final imported = await ShelfApi.importLocalBytes(
          [
            (
              name: '缓存多选$n.txt',
              bytes: utf8.encode(text.toString()),
            ),
          ],
          0,
          homeDir: home.path,
        );
        final id = ((imported['imported'] as List).first as Map)['id'] as int;
        result.add(id);
        await ToolsApi.cacheStart(id, 'chapters', indexes: [0, 1]);
        // 等后台任务落库，缓存页才有书可列。
        for (var i = 0; i < 200; i++) {
          final jobs = await LegadoClient.instance.callList('Cache.Jobs');
          final job = jobs.where((j) => j['bookId'] == id).cast<Map<String, dynamic>>();
          if (job.isNotEmpty && job.first['state'] != 'running') break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      }
      return result;
    });
    return ids ?? <int>[];
  }

  testWidgets('长按进入多选，全选后批量清除缓存', (tester) async {
    await tester.runAsync(() => ToolsApi.cacheClear());
    final ids = await importAndCacheBooks(tester, 2);
    expect(ids, hasLength(2));

    await tester.pumpWidget(const MaterialApp(home: CachePage()));
    await settle(tester);
    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.textContaining('已缓存 2/4 章'), findsNWidgets(2));

    // 长按书项进入多选。
    await tester.longPress(find.textContaining('已缓存 2/4 章').first);
    await settle(tester);
    expect(find.text('已选 1 项'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget);

    // 全选 → 两本都勾上。
    await tester.tap(find.byTooltip('全选'));
    await settle(tester);
    expect(find.text('已选 2 项'), findsOneWidget);

    // 批量清除 → 确认；完成后退出多选且列表清空。
    await tester.tap(find.byTooltip('批量操作'));
    await settle(tester);
    await tester.tap(find.text('清除所选缓存'));
    await settle(tester);
    expect(find.textContaining('将删除所选 2 本书'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '清除 2 本'));
    await settle(tester);

    await tester.runAsync(() async {
      final books = await ToolsApi.cacheBooks();
      expect(books, isEmpty);
    });
    expect(find.text('缓存管理'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('章节面板可多选并批量删除', (tester) async {
    await tester.runAsync(() => ToolsApi.cacheClear());
    final ids = await importAndCacheBooks(tester, 1);

    await tester.pumpWidget(const MaterialApp(home: CachePage()));
    await settle(tester);

    await tester.tap(find.textContaining('已缓存 2/4 章'));
    await settle(tester);
    expect(find.textContaining('长按可多选'), findsOneWidget);

    // 面板标题行的「多选」按钮进入。
    await tester.tap(find.text('多选'));
    await settle(tester);
    expect(find.text('已选 1 章'), findsNWidgets(2)); // 标题 + 底部条

    await tester.tap(find.text('删除选中'));
    await settle(tester);
    expect(find.text('将删除所选 1 章缓存，确定继续？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await settle(tester);

    await tester.runAsync(() async {
      final chapters = await ToolsApi.cacheChapters(ids.first);
      expect(chapters, hasLength(1));
    });
    expect(find.textContaining('已缓存 1 章'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
