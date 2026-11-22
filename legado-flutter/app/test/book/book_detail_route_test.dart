import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/router/book_detail_route.dart';
import 'package:legado/core/router/routes.dart';

/// 回归用例：从搜索页（输入框有焦点）进详情页再返回，输入法不能再被唤起。
///
/// 现象：Flutter 的 FocusScope 会按 route 保存焦点，pop 回来时恢复 →
/// `EditableText` 重新打开输入连接 → 安卓端"返回时突然弹出输入法"。
/// `openBookDetail` 在 push 前 `unfocus()`，焦点交还给 scope 而不是输入框。
void main() {
  testWidgets('openBookDetail 释放焦点，返回后不重开输入连接', (tester) async {
    final ctrl = TextEditingController();
    addTearDown(ctrl.dispose);

    await tester.pumpWidget(
      MaterialApp(
        routes: {
          '/': (ctx) => Scaffold(
            appBar: AppBar(title: TextField(controller: ctrl)),
            body: Builder(
              builder: (inner) => Center(
                child: TextButton(
                  onPressed: () => openBookDetail(
                    inner,
                    bookId: 1,
                    bookName: '测试书',
                  ),
                  child: const Text('打开详情'),
                ),
              ),
            ),
          ),
          RouteNames.bookDetail: (_) =>
              const Scaffold(body: Center(child: Text('详情页'))),
        },
      ),
    );

    // 模拟搜索：点输入框，键盘（输入连接）打开。
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue);

    await tester.tap(find.text('打开详情'));
    await tester.pumpAndSettle();
    expect(find.text('详情页'), findsOneWidget);

    // 返回：焦点若被恢复到输入框，这里会重新打开输入连接。
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(
      FocusManager.instance.primaryFocus?.context?.widget,
      isNot(isA<EditableText>()),
    );
  });
}
