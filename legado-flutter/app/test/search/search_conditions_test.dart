import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/search/search_page.dart';
import 'package:legado/features/settings/settings_api.dart';
import 'package:legado/features/settings/settings_store.dart';

/// 搜索页条件对齐原版：精确搜索与范围都要跨会话记住，并在搜索页直接可改。
/// 设置用假 caller 注入，避免依赖内核设置表；范围列表需要真实书源表。
void main() {
  late Directory home;

  setUpAll(() async {
    home = await Directory.systemTemp.createTemp('legado-search-cond');
    await LegadoClient.connect(homeDir: home.path);
  });

  tearDownAll(() async {
    if (LegadoClient.isReady) await LegadoClient.instance.dispose();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  SettingsStore storeFor(Map<String, String> values) => SettingsStore(
    caller: (method, args) async {
      switch (method) {
        case SettingsApi.schema:
          return jsonDecode(
            File('test/fixtures/settings_schema.json').readAsStringSync(),
          );
        case SettingsApi.values:
          return Map<String, String>.from(values);
        case SettingsApi.update:
          final patch = args.first as Map<String, String>;
          patch.forEach((key, value) => values[key] = value);
          return Map<String, String>.from(values);
        default:
          return <String, String>{};
      }
    },
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('精确搜索与范围从设置恢复，切换后写回', (tester) async {
    final values = <String, String>{
      'search.precision': 'true',
      'search.scope': '小说',
    };
    final store = storeFor(values);
    await tester.pumpWidget(MaterialApp(home: SearchPage(settings: store)));
    await settle(tester);

    expect(find.text('搜索范围：小说'), findsOneWidget);
    expect(find.text('精确'), findsOneWidget);

    // 原版菜单项是可勾选的「精确搜索」，关掉后标签消失且设置落盘。
    await tester.tap(find.byTooltip('搜索选项'));
    await tester.pumpAndSettle();
    expect(find.text('精确搜索'), findsOneWidget);
    await tester.tap(find.text('精确搜索'));
    await settle(tester);

    expect(values['search.precision'], 'false');
    expect(find.text('精确'), findsNothing);
  });

  testWidgets('范围面板可选择指定书源并持久化', (tester) async {
    // 真实内核建一个源，范围面板的书源列表不能造假数据。
    await tester.runAsync(() async {
      await LegadoClient.instance.call('Source.Save', [
        0,
        '范围测试源',
        '测试分组',
        'https://scope.example',
        '',
        jsonEncode({
          'bookSourceUrl': 'https://scope.example',
          'bookSourceName': '范围测试源',
          'bookSourceGroup': '测试分组',
          'enabled': true,
          'searchUrl': 'https://scope.example/search?q={{key}}',
          'ruleSearch': jsonEncode({
            'bookList': '.item',
            'name': '.title@text',
            'author': '.author@text',
            'bookUrl': '.title@href',
          }),
        }),
        true,
        0,
      ]);
    });

    final values = <String, String>{};
    final store = storeFor(values);
    await tester.pumpWidget(MaterialApp(home: SearchPage(settings: store)));
    await settle(tester);

    await tester.tap(find.text('搜索范围：全部书源'));
    await settle(tester);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('测试分组'), findsWidgets);

    await tester.tap(find.text('范围测试源'));
    await settle(tester);
    await tester.tap(find.text('确定'));
    await settle(tester);

    expect(
      values['search.scope'],
      '范围测试源::https://scope.example',
      reason: '范围要用原版「名称::地址」格式存，内核 SearchAll 才能解析',
    );
    expect(find.text('搜索范围：范围测试源'), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
