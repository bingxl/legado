import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/source/source_edit_page.dart';

/// 编辑页的「新建」分支不依赖 core，可以在没有 bridge 的情况下直接渲染。
void main() {
  Future<void> pumpEdit(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SourceEditPage()));
    await tester.pumpAndSettle();
  }

  Finder rawField() => find.byType(TextField).last;

  testWidgets('新建时展示空表单', (tester) async {
    await pumpEdit(tester);
    expect(find.text('新建书源'), findsOneWidget);
    expect(find.text('书源地址 *'), findsOneWidget);
    expect(find.text('原始 JSON'), findsOneWidget);
  });

  testWidgets('raw JSON 语法错误即时提示', (tester) async {
    await pumpEdit(tester);
    await tester.enterText(rawField(), '{"a": }');
    await tester.pump();
    expect(find.textContaining('JSON 格式错误'), findsOneWidget);
  });

  testWidgets('无地址时保存被表单校验拦住', (tester) async {
    await pumpEdit(tester);
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('书源地址不能为空'), findsOneWidget);
  });

  testWidgets('用 JSON 补齐表单', (tester) async {
    await pumpEdit(tester);
    await tester.enterText(
      rawField(),
      '{"bookSourceName":"示例源","bookSourceUrl":"https://a.example.com",'
      '"bookSourceGroup":"测试"}',
    );
    await tester.pump();
    await tester.tap(find.text('用 JSON 补齐表单'));
    await tester.pump();

    final url = tester.widget<TextFormField>(find.byType(TextFormField).at(2));
    expect(url.controller?.text, 'https://a.example.com');
    final name = tester.widget<TextFormField>(find.byType(TextFormField).at(0));
    expect(name.controller?.text, '示例源');
  });
}
