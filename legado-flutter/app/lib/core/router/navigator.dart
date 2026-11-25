import 'package:flutter/material.dart';

/// 全局导航键。
///
/// 内核的回调（反爬人机验证）发生在规则求值过程中，手上没有 `BuildContext`，
/// 只能通过它拿到 Navigator 来开验证页。整个应用只该有一个。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
