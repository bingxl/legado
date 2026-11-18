import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/router/routes.dart';
import '../shelf/shelf_page.dart';

/// 主框架：对应原版 `activity_main.xml` 的 ViewPager + BottomNavigationView。
///
/// 四个 tab 与官方一致：书架 / 发现 / 订阅 / 我的。
/// 桌面端在 [NavigationBar] 之上补充键盘快捷键（Alt+1..4），
/// 属于 MODULE-PLAN §8 的「交互翻译层」。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialIndex;

  static const _items = <_TabItem>[
    _TabItem('书架', Icons.book_outlined, Icons.book),
    _TabItem('发现', Icons.explore_outlined, Icons.explore),
    _TabItem('订阅', Icons.rss_feed_outlined, Icons.rss_feed),
    _TabItem('我的', Icons.person_outline, Icons.person),
  ];

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.digit1, alt: true): _SwitchTabIntent(0),
        SingleActivator(LogicalKeyboardKey.digit2, alt: true): _SwitchTabIntent(1),
        SingleActivator(LogicalKeyboardKey.digit3, alt: true): _SwitchTabIntent(2),
        SingleActivator(LogicalKeyboardKey.digit4, alt: true): _SwitchTabIntent(3),
      },
      child: Actions(
        actions: {
          _SwitchTabIntent: CallbackAction<_SwitchTabIntent>(
            onInvoke: (intent) {
              setState(() => _index = intent.index);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: IndexedStack(
              index: _index,
              children: [
                const ShelfPage(),
                buildPlaceholderRoute(context, RouteNames.explore),
                buildPlaceholderRoute(context, RouteNames.rss),
                buildPlaceholderRoute(context, RouteNames.me),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              destinations: [
                for (final it in _items)
                  NavigationDestination(
                    icon: Icon(it.icon),
                    selectedIcon: Icon(it.selectedIcon),
                    label: it.label,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  const _TabItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _SwitchTabIntent extends Intent {
  const _SwitchTabIntent(this.index);

  final int index;
}
