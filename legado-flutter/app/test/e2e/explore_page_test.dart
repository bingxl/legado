// 发现页的真实渲染测试：连内核 → 真实书源 → 点书源展开分类。
//
// 与 real_source_test.dart 的区别：那个测内核 API，这个测 Widget 渲染与交互。
// 需要联网，同样用 LEGADO_E2E=1 开关。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/explore/explore_page.dart';

void main() {
  final enabled = Platform.environment['LEGADO_E2E'] == '1';

  testWidgets('发现页渲染真实书源并能展开分类', (tester) async {
    if (!enabled) return;
    await LegadoClient.connect();

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ExplorePage())),
    );
    // 等首屏加载
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // 书源列表应非空
    final sourceTiles = find.textContaining('漫画客');
    expect(sourceTiles, findsWidgets, reason: '发现页没有渲染出真实书源');

    // 点开一个可直连的书源，等分类 chip 出现
    await tester.tap(find.text('神奇漫画').first);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 展开后应能看到分类 chip（原文里的「全部」「复仇」等）
    final kinds = find.text('复仇');
    expect(kinds, findsWidgets, reason: '展开书源后没有渲染出发现分类');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
