import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'reader_controller.dart';
import 'reader_style.dart';
import 'widgets/chapter_sheet.dart';
import 'widgets/reader_menu.dart';
import 'widgets/reader_pager.dart';
import 'widgets/reader_scroll_view.dart';
import 'widgets/tts_sheet.dart';

/// 阅读页入口。
///
/// 路由参数约定：`{'bookId': int, 'bookName': String?, 'chapterIndex': int?}`。
/// [initialChapter] 默认 -1，表示按 core 记录的进度续读。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.bookId,
    this.initialChapter = -1,
    this.bookName,
  });

  final int bookId;
  final int initialChapter;
  final String? bookName;

  /// 方便壳层用 `onGenerateRoute` 直接接进来（路由表本身是冻结文件，不在本模块改）。
  static Widget fromRouteArguments(Object? args) {
    final map = args is Map ? args : const <String, Object?>{};
    return ReaderPage(
      bookId: (map['bookId'] as num?)?.toInt() ?? 0,
      initialChapter: (map['chapterIndex'] as num?)?.toInt() ?? -1,
      bookName: map['bookName'] as String?,
    );
  }

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  final GlobalKey<ReaderPagerState> _pagerKey = GlobalKey<ReaderPagerState>();
  final GlobalKey<ReaderScrollViewState> _scrollKey =
      GlobalKey<ReaderScrollViewState>();
  final FocusNode _focus = FocusNode(debugLabel: 'reader');

  late final ReaderController _controller;
  bool _menu = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ReaderController(
      bookId: widget.bookId,
      initialChapter: widget.initialChapter,
      style: ReaderStyleStore.style,
      initialBookName: widget.bookName,
    )..addListener(_onControllerChanged);
    _controller.load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/锁屏前落盘，避免被系统杀掉时丢进度。
    if (state != AppLifecycleState.resumed) {
      _controller.saveProgress(force: true);
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  void _setMenu(bool visible) {
    if (_menu == visible) return;
    setState(() => _menu = visible);
    // 菜单里的按钮会抢焦点，关掉后把焦点还给根节点，键盘翻页才能继续用。
    if (!visible) _focus.requestFocus();
  }

  void _toggleMenu() => _setMenu(!_menu);

  void _turn(int dir) {
    if (_menu) _setMenu(false);
    if (_controller.style.pageTurn == PageTurnMode.scroll) {
      _scrollKey.currentState?.scrollByPage(dir);
      return;
    }
    final pager = _pagerKey.currentState;
    if (pager != null) {
      pager.turn(dir);
    } else {
      _controller.turnPage(dir);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // 按住不放要连续翻页，所以 KeyRepeatEvent 也要处理。
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (_menu) {
        _setMenu(false);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.pageUp) {
      _turn(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.pageDown) {
      _turn(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      _turn(1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _close() {
    _controller.saveProgress(force: true);
    Navigator.of(context).maybePop();
  }

  void _seek(double percent) {
    final total = _controller.chapters.length;
    if (total == 0) return;
    final index = (percent * total).floor().clamp(0, total - 1);
    _controller.openChapter(index);
    _focus.requestFocus();
  }

  Future<void> _openToc() async {
    await showChapterSheet(context, _controller);
    _focus.requestFocus();
  }

  Future<void> _openTts() async {
    await showTtsSheet(context, _controller);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final style = _controller.style;
    final background = style.background;

    return PopScope(
      // 菜单打开时返回键先关菜单，而不是直接退出阅读器。
      canPop: !_menu,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _menu) _setMenu(false);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // 夜间背景需要浅色状态栏图标，否则系统栏在纯黑背景上看不见。
        value: background.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: Scaffold(
          backgroundColor: background.color,
          body: SafeArea(
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  if (size.isFinite && !size.isEmpty) {
                    // 允许在 build 阶段调用：ensureLayout 内部不 notify，
                    // 避免「首帧空页 → postFrame 重排」的闪烁。
                    _controller.ensureLayout(size);
                  }
                  return Stack(
                    children: [
                      Positioned.fill(child: _body(background)),
                      if (_controller.chapterLoading)
                        const Align(
                          alignment: Alignment.topCenter,
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      Positioned.fill(
                        child: ReaderMenuOverlay(
                          controller: _controller,
                          visible: _menu,
                          onClose: _close,
                          onOpenToc: _openToc,
                          onPrevChapter: _controller.prevChapter,
                          onNextChapter: _controller.nextChapter,
                          onStyleChanged: _controller.applyStyle,
                          onSpeak: _openTts,
                          onSeek: _seek,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ReaderBackground background) {
    if (_controller.loading) {
      return Center(
        child: CircularProgressIndicator(color: background.textColor),
      );
    }
    if (_controller.error != null && _controller.pages.isEmpty) {
      return _errorView(background);
    }
    if (_controller.isManga) {
      return _MangaPlaceholder(
        images: _controller.images,
        onTapCenter: _toggleMenu,
        textColor: background.textColor,
      );
    }
    if (_controller.pages.isEmpty) {
      return _hint(
        background,
        _controller.hasContent ? '本章暂无正文' : '本章内容为空，可能被屏蔽或需要购买',
      );
    }
    if (_controller.style.pageTurn == PageTurnMode.scroll) {
      return ReaderScrollView(
        key: _scrollKey,
        controller: _controller,
        style: _controller.style,
        menuVisible: _menu,
        onTapCenter: _toggleMenu,
      );
    }
    return ReaderPager(
      key: _pagerKey,
      controller: _controller,
      style: _controller.style,
      menuVisible: _menu,
      onTapCenter: _toggleMenu,
    );
  }

  Widget _errorView(ReaderBackground background) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 36,
              color: background.textColor,
            ),
            const SizedBox(height: 12),
            Text(
              _controller.error ?? '加载失败',
              textAlign: TextAlign.center,
              style: TextStyle(color: background.textColor),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _controller.load, child: const Text('重试')),
          ],
        ),
      ),
    );
  }

  Widget _hint(ReaderBackground background, String text) {
    return Center(
      child: Text(
        text,
        style: TextStyle(color: background.textColor.withValues(alpha: 0.7)),
      ),
    );
  }
}

/// 漫画章占位。core 的 `/img` 数据面还没接，先按图片数量画占位框，
/// 让分页/翻页/菜单等交互在漫画书上也能跑通。
class _MangaPlaceholder extends StatelessWidget {
  const _MangaPlaceholder({
    required this.images,
    required this.onTapCenter,
    required this.textColor,
  });

  final List<String> images;
  final VoidCallback onTapCenter;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTapCenter,
      child: ListView.builder(
        itemCount: images.length,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AspectRatio(
              aspectRatio: 0.72,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: textColor.withValues(alpha: 0.25)),
                  borderRadius: BorderRadius.circular(6),
                  color: textColor.withValues(alpha: 0.05),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.image_outlined,
                        size: 36,
                        color: textColor.withValues(alpha: 0.5),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '第 ${index + 1} 页',
                        style: TextStyle(
                          fontSize: 12,
                          color: textColor.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '图片数据面未接入',
                        style: TextStyle(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
