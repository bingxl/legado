import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/image_url.dart';
import 'reader_controller.dart';
import 'reader_prefs.dart';
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
///
/// `chapterIndex` 与 `initialChapter` 都收：前者是路由参数名，后者是构造参数名，
/// 外部（书签/阅读记录/书架）传哪一个都能跳对章节。
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
    // 两个键都认（见类注释）；都没传时 -1 表示「续读 core 记录的进度」。
    final chapter =
        (map['chapterIndex'] as num?) ?? (map['initialChapter'] as num?);
    return ReaderPage(
      bookId: (map['bookId'] as num?)?.toInt() ?? 0,
      initialChapter: chapter?.toInt() ?? -1,
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

  /// 退出询问的防重入标记：系统返回键与菜单返回按钮可能在同一帧都触发，
  /// 没有它就会叠出两个对话框。
  bool _exiting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ReaderController(
      bookId: widget.bookId,
      initialChapter: widget.initialChapter,
      // 首次进入时按 core 里存的偏好排版；之后菜单里的调整会写回 core。
      style: ReaderPrefs.style,
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
    unawaited(_requestExit());
  }

  /// 菜单里改完字号/背景/翻页方式后：先应用到当前页面，再写回 core。
  ///
  /// 落盘是异步的且不许失败影响阅读，所以不 await；同一批改动在设置存储里
  /// 会按 key 合并，不会因为连续点几下字号就发一堆请求。
  void _applyStyle(ReaderStyle next) {
    _controller.applyStyle(next);
    ReaderPrefs.persist(next);
  }

  /// 带「试读转正」询问的退出。
  ///
  /// 规则来自设置项 `general.promptAddToShelf`（默认关闭）：
  /// 开关关着、或这本书已在书架，就直接退；否则问一次。
  /// 顺序不能反——先看开关再看 inShelf，否则每次退出都要多一次查询。
  Future<void> _requestExit() async {
    if (_exiting) return;
    _exiting = true;
    // 先取出 navigator：下面要走 await（查书架、弹对话框），
    // 之后再用 context 就会被 lint 判为跨异步间隙使用。
    final navigator = Navigator.of(context);
    try {
      _controller.saveProgress(force: true);
      if (ReaderPrefs.promptAddToShelf &&
          !await ReaderPrefs.inShelf(widget.bookId)) {
        if (!mounted) return;
        final added = await _askAddToShelf();
        if (added) await ReaderPrefs.addToShelf(widget.bookId);
        if (!mounted) return;
      }
      navigator.pop();
    } finally {
      _exiting = false;
    }
  }

  /// 询问是否加入书架。返回 true 表示用户选了「加入书架」。
  Future<bool> _askAddToShelf() async {
    final background = _controller.style.background;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: background.dark ? const Color(0xFF262626) : null,
        title: Text(
          '加入书架？',
          style: background.dark
              ? const TextStyle(color: Color(0xFFEDEDED))
              : null,
        ),
        content: Text(
          '《${_controller.bookTitle}》还没加入书架，加入后可以在书架继续阅读。',
          style: background.dark
              ? const TextStyle(color: Color(0xFFBDBDBD))
              : null,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续试读'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('加入书架'),
          ),
        ],
      ),
    );
    return result ?? false;
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
      // 一律拦下来自己做：菜单打开时先关菜单；否则走「试读转正」询问。
      // canPop 置 false 后必须自己 pop，否则返回键会失效（见 _requestExit）。
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_menu) {
          _setMenu(false);
          return;
        }
        unawaited(_requestExit());
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
                          onStyleChanged: _applyStyle,
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
      return _MangaView(
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

/// 漫画章：按顺序铺开图片。
///
/// 漫画的「正文」本质是图片直链列表（core 的 `Reader.GetContent.images`），
/// 没有分页数据，因此这里用 ListView 而不是分页器；单击任意位置仍然呼出菜单，
/// 与文字章的交互一致。
class _MangaView extends StatelessWidget {
  const _MangaView({
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
        // 预取两屏，快速下滑时不至于频繁看到加载骨架。
        cacheExtent: 1200,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemBuilder: (context, index) =>
            _MangaImage(url: images[index], index: index, textColor: textColor),
      ),
    );
  }
}

/// 单页漫画图片。
///
/// 失败/相对地址/空串都渲染成可读的占位块，而不是抛异常或留一片白：
/// 漫画源常见的图片 CDN 会过期，用户至少要能看出「这一页失败了」。
class _MangaImage extends StatelessWidget {
  const _MangaImage({
    required this.url,
    required this.index,
    required this.textColor,
  });

  final String url;
  final int index;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final src = normalizeImageUrl(url);
    if (src == null) return _failure('第 ${index + 1} 页图片地址无效');

    // 大图按屏幕宽度解码，避免整章几十张原图把内存打满。
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).round();

    return Image.network(
      src,
      // 图片 CDN 防盗链：不带 Referer 会 403（超星图片尤其明显）。
      headers: imageHeaders(src),
      width: double.infinity,
      fit: BoxFit.fitWidth,
      filterQuality: FilterQuality.medium,
      cacheWidth: cacheWidth > 0 ? cacheWidth : null,
      gaplessPlayback: true,
      semanticLabel: '第 ${index + 1} 页',
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return _loading();
      },
      errorBuilder: (context, error, stackTrace) =>
          _failure('第 ${index + 1} 页加载失败'),
    );
  }

  Widget _loading() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 320),
      alignment: Alignment.center,
      color: textColor.withValues(alpha: 0.04),
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: textColor.withValues(alpha: 0.35),
        ),
      ),
    );
  }

  Widget _failure(String message) {
    return Container(
      width: double.infinity,
      height: 200,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: textColor.withValues(alpha: 0.2)),
        borderRadius: BorderRadius.circular(6),
        color: textColor.withValues(alpha: 0.04),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 32,
            color: textColor.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              fontSize: 12,
              color: textColor.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}
