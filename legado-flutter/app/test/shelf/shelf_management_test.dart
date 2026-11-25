import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/api.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/core/router/routes.dart';
import 'package:legado/features/shelf/shelf_api.dart';
import 'package:legado/features/shelf/shelf_manage_page.dart';
import 'package:legado/features/shelf/shelf_page.dart';

/// 书架三个新入口的 widget 测试：分组管理、书架管理、目录刷新入口。
/// 用真实内核 + 临时 home，避免给 LegadoClient 再造一层注入接口。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-shelf-ui');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  testWidgets('书架「更多」菜单提供分组管理 / 书架管理 / 更新目录', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ShelfPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    expect(find.text('分组管理'), findsOneWidget);
    expect(find.text('书架管理'), findsOneWidget);
    expect(find.text('更新目录'), findsOneWidget);
    expect(find.text('导入书架 JSON'), findsOneWidget);
    expect(find.text('导出书架 JSON'), findsOneWidget);
  });

  testWidgets('分组管理可新建分组并显示在列表里', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ShelfPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分组管理'));
    await tester.pumpAndSettle();

    expect(find.text('分组管理'), findsOneWidget);
    await tester.tap(find.text('新增分组'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '测试分组');
    await tester.pump();
    // 名称 TextField 是弹窗里第一个输入框，封面输入框在它后面。
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('测试分组'), findsWidgets);
  });

  testWidgets('书架管理页支持搜索过滤、全选与批量操作栏', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        routes: {
          RouteNames.shelfManage: (_) =>
              ShelfManagePage.fromRouteArguments({'groupId': 0}),
        },
        home: const ShelfPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('书架管理'));
    await tester.pumpAndSettle();

    expect(find.text('书架管理'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('取消选中'), findsOneWidget);
    // 空书架时所有批量按钮都在，但没有选中项 → 全部禁用。
    expect(find.text('移动分组'), findsOneWidget);
    expect(find.text('加入分组'), findsOneWidget);
    expect(find.text('允许更新'), findsOneWidget);
    expect(find.text('禁止更新'), findsOneWidget);
    expect(find.text('批量换源'), findsOneWidget);
    expect(find.text('清缓存'), findsOneWidget);
    expect(find.text('移出书架'), findsOneWidget);
    expect(find.text('长按一本书并拖动可连续选择'), findsOneWidget);
  });

  testWidgets('长按书架书籍进入详情页（网格与列表都生效）', (tester) async {
    // 用真实内核导入一本本地书，不造假 dto。widget test 跑在 fake-async zone，
    // 真实文件 IO + sqlite 必须放进 runAsync，否则 await 永远不返回。
    List<Map<String, dynamic>> books = const [];
    Map<String, dynamic>? imported;
    await tester.runAsync(() async {
      imported = await ShelfApi.importLocalBytes(
        [
          (
            name: '长按目标.txt',
            bytes: utf8.encode('第一章 开始\n正文内容。\n'),
          ),
        ],
        0,
        homeDir: home.path,
      );
      books = await LegadoClient.instance.callList(Api.shelfListBooks, [0]);
    });
    // 文件名会被清洗（中文→下划线 + 时间戳前缀），直接用内核返回的书名。
    expect(imported?['imported'], isNotEmpty);
    final name = books.first['name'] as String;

    // 书架有书后 RefreshIndicator/封面等会让 pumpAndSettle 等不到静止帧，
    // 这里用固定帧驱动，保证测试能结束。
    Future<void> settle() async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(
      MaterialApp(
        routes: {
          RouteNames.bookDetail: (_) => const Scaffold(
            body: Center(child: Text('书籍详情页')),
          ),
        },
        home: const ShelfPage(),
      ),
    );
    await settle();

    // 网格视图：长按进详情页。
    expect(find.text(name), findsOneWidget);
    await tester.longPress(find.text(name));
    await settle();
    expect(find.text('书籍详情页'), findsOneWidget);

    // 返回后切列表视图，再验证一次。
    Navigator.of(tester.element(find.text('书籍详情页'))).pop();
    await settle();
    await tester.tap(find.byTooltip('切换列表'));
    await settle();
    await tester.longPress(find.text(name));
    await settle();
    expect(find.text('书籍详情页'), findsOneWidget);
  });
}
