import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/settings/settings_page.dart';

void main() {
  testWidgets('设置页：未连接 core 时显示错误态与重试', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
