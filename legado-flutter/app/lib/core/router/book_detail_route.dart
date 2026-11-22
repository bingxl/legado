import 'package:flutter/material.dart';

import 'routes.dart';

/// 打开书籍详情页。所有入口都应走这里，不要直接 `pushNamed`。
///
/// 为什么必须统一：Flutter 的焦点系统会按 route 记住焦点。如果 push 之前
/// 某个输入框还持有焦点（最典型是搜索页 AppBar 里的搜索框 —— 用户刚打完
/// 关键字就点了搜索结果），pop 回上一页时焦点会被"恢复"，`EditableText`
/// 重新打开输入连接，安卓上就表现为**返回时突然弹出输入法**。
/// 进入新页面时键盘会收起（route 不再是 current），所以问题只在返回那一刻暴露，
/// 且只有"进页面前焦点在输入框上"才复现 —— 这就是用户说的"偶尔"。
///
/// push 前显式 `unfocus()` 会把焦点交还给 route 的 scope（不是输入框），
/// 返回时没有可恢复的输入节点，输入法不会再弹。
Future<T?> openBookDetail<T>(
  BuildContext context, {
  required int bookId,
  String? bookName,
}) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.pushNamed<T>(
    context,
    RouteNames.bookDetail,
    arguments: {'bookId': bookId, 'bookName': bookName},
  );
}
