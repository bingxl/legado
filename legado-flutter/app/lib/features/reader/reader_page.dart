import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/cached_reader_image.dart';
import '../tools/tools_api.dart';
import 'progress.dart';
import 'reader_controller.dart';
import 'reader_prefs.dart';
import 'reader_style.dart';
import 'tap_zone.dart';
import 'widgets/cache_range_dialog.dart';
import 'widgets/chapter_sheet.dart';
import 'widgets/error_retry_view.dart';
import 'widgets/image_viewer_page.dart';
import 'widgets/overscroll_accumulator.dart';
import 'widgets/reader_menu.dart';
import 'widgets/reader_pager.dart';
import 'widgets/reader_scroll_view.dart';
import 'widgets/tts_sheet.dart';

/// 阅读页入口。
///
/// 路由参数约定：
/// `{'bookId': int, 'bookName': String?, 'chapterIndex': int?, 'chapterPos': int?}`。
/// [initialChapter] / [initialChapterPos] 默认 -1，表示按 core 记录的进度续读。
///
/// `chapterIndex` 与 `initialChapter` 都收：前者是路由参数名，后者是构造参数名，
/// 外部（书签/阅读记录/书架）传哪一个都能跳对章节。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.bookId,
    this.initialChapter = -1,
    this.initialChapterPos = -1,
    this.bookName,
  });

  final int bookId;
  final int initialChapter;

  /// 章内位置（文字章是字符偏移，漫画章是第几张图）。
  ///
  /// -1 表示「没指定」，此时：显式指定了章节就从章首开始（不沿用旧进度偏移，
  /// 否则会莫名跳到同章后半段）；没指定章节则续读 core 里记录的 `chapterPos`。
  final int initialChapterPos;

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
      initialChapterPos: (map['chapterPos'] as num?)?.toInt() ?? -1,
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
  final GlobalKey<_MangaViewState> _mangaKey = GlobalKey<_MangaViewState>();
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
      initialChapterPos: widget.initialChapterPos,
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
        backgroundColor: background.dark ? kReaderDarkPanel : null,
        title: Text(
          '加入书架？',
          style: background.dark
              ? const TextStyle(color: kReaderDarkForeground)
              : null,
        ),
        content: Text(
          '《${_controller.bookTitle}》还没加入书架，加入后可以在书架继续阅读。',
          style: background.dark
              ? const TextStyle(color: kReaderDarkMuted)
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

  /// 翻到全书边界再继续翻时的提示（对齐原版「没有下一页」的 snackbar）。
  ///
  /// 没有它的话，最后一章末页点「下一页」看起来就是点击失灵；
  /// 频繁点击时只保留一条，避免 SnackBar 排队。
  void _showBoundaryHint(int dir) {
    final messenger = ScaffoldMessenger.of(context);
    if (messenger.mounted && mounted) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(dir > 0 ? '已经是最后一章' : '已经是第一章'),
          duration: const Duration(milliseconds: 1200),
        ),
      );
    }
  }

  /// 菜单进度条：只在**本章**内跳页，不跨章。
  ///
  /// 原版 `ReadMenu` 的默认 `progressBarBehavior = "page"`，seekBar 的
  /// `max` 是 `pageSize - 1`、松手调用 `ReadBook.skipToPage`；
  /// 全书跳章是另一个可选模式，默认不开。这里按默认行为对齐。
  void _seek(double percent) {
    final controller = _controller;
    if (controller.isManga) {
      // 漫画章按本章图片张数跳（原版 MangaMenu.skipToPage），
      // 不按全书页数，也不跨章。
      final index = indexForReadPercent(percent, controller.imageCount);
      _mangaKey.currentState?.scrollToImage(index);
      _focus.requestFocus();
      return;
    }
    final count = controller.pageCount;
    if (count == 0) return;
    // 末页对应 100%：按 count-1 取整，拖到最右侧一定落在最后一页。
    final index = indexForReadPercent(percent, count);
    if (controller.style.pageTurn == PageTurnMode.scroll) {
      _scrollKey.currentState?.jumpToPage(index);
    } else {
      _pagerKey.currentState?.jumpToPage(index);
    }
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

  /// 菜单里的「刷新正文」：跳过离线缓存重新抓一次当前章。
  ///
  /// 只影响当前章，不动已缓存的其它章；失败会回退到刚看的那一版。
  Future<void> _refreshChapter() async {
    _setMenu(false);
    final ok = await _controller.refreshChapter();
    if (!mounted) return;
    _focus.requestFocus();
    final message = ok
        ? '已重新抓取本章正文'
        : (_controller.error == null ? '刷新失败，仍显示原来的正文' : '刷新失败，请检查书源或网络');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// 菜单里的「离线缓存」：默认缓存当前章到末章，范围可在弹层里改。
  ///
  /// 不用 `Cache.Start(scope: 'remaining')`：那个 scope 读的是 core 里落盘的
  /// `durChapterIndex`，用户正在读的章还没落盘，起点会差一章。这里把阅读器
  /// 内存里的当前章换成显式下标列表，语义与原版 `showDownloadDialog` 一致。
  void _toast(String message) =>
      showAppToast(context, message, mounted: mounted);

  Future<void> _cacheChapters() async {
    _setMenu(false);
    final total = _controller.chapters.length;
    if (total == 0 || _controller.bookId <= 0) {
      _toast('本书暂时没有可缓存的章节');
      return;
    }
    final current = (_controller.chapterIndex + 1).clamp(1, total);
    final range = await showCacheRangeDialog(
      context: context,
      currentChapter: current,
      totalChapters: total,
    );
    if (!mounted) return;
    _focus.requestFocus();
    if (range == null) return;

    try {
      await ToolsApi.cacheStart(
        _controller.bookId,
        'chapters',
        indexes: range.indexes,
      );
    } on LegadoError catch (e) {
      _toast('缓存失败：${e.message}');
      return;
    } catch (e) {
      _toast('缓存失败：$e');
      return;
    }
    _toast('已开始缓存第 ${range.start} 至 ${range.end} 章（共 ${range.count} 章）');
  }

  /// 菜单「书签」：在当前章当前位置加一条。
  ///
  /// core 的 Bookmark.Add 早已实现，但 app 侧此前没有任何调用点，书签页的
  /// 空态还提示「在阅读器点书签按钮」——按钮根本不存在。这里补上。
  Future<void> _addBookmark() async {
    _setMenu(false);
    try {
      await ToolsApi.bookmarkAdd(
        bookId: _controller.bookId,
        chapterIndex: _controller.chapterIndex,
        chapterTitle: _controller.chapterTitle,
        chapterPos: _controller.isManga
            ? _controller.imageIndex
            : (_controller.currentPage?.startOffset ?? 0),
      );
      _toast('已添加书签');
    } on LegadoError catch (e) {
      _toast('添加书签失败：${e.message}');
    } catch (e) {
      _toast('添加书签失败：$e');
    }
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
                          onRefresh: _refreshChapter,
                          onCache: _cacheChapters,
                          onBookmark: _addBookmark,
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

  /// 双击正文插图/网络漫画图片 → 打开全屏看图。
  /// [urls] 是本章图源列表，[url] 是被双击的那张，用来定位初始页。
  void _openImageViewer(List<String> urls, String url) {
    final sources = resolveViewerSources(urls, url);
    if (sources == null) return;
    unawaited(
      ImageViewerPage.open(
        context,
        count: sources.urls.length,
        initialIndex: sources.index,
        title: _controller.chapterTitle,
        imageBuilder: (ctx, i) {
          final url = sources.urls[i];
          return CachedReaderImage(
            url: url,
            localPath: _controller.imagePathOf(url),
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => viewerImageErrorPlaceholder,
          );
        },
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
        key: _mangaKey,
        controller: _controller,
        onTapCenter: _toggleMenu,
        onBoundary: _showBoundaryHint,
        textColor: background.textColor,
        onImageDoubleTap: (index) =>
            _openImageViewer(_controller.images, _controller.images[index]),
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
        onBoundary: _showBoundaryHint,
        onImageDoubleTap: (url) =>
            _openImageViewer(_controller.inlineImages, url),
        localImagePath: _controller.imagePathOf,
      );
    }
    return ReaderPager(
      key: _pagerKey,
      controller: _controller,
      style: _controller.style,
      menuVisible: _menu,
      onTapCenter: _toggleMenu,
      onBoundary: _showBoundaryHint,
      onImageDoubleTap: (url) =>
          _openImageViewer(_controller.inlineImages, url),
      localImagePath: _controller.imagePathOf,
    );
  }

  Widget _errorView(ReaderBackground background) {
    return ErrorRetryView(
      message: _controller.error ?? '加载失败',
      icon: Icons.cloud_off_outlined,
      iconSize: 36,
      color: background.textColor,
      // 重试要能甩掉缓存：缓存里若是坏内容（防爬占位页、抓到半截），
      // 普通重读永远还是它，看起来就是「怎么点都没用」。
      onRetry: () {
        if (_controller.chapters.isEmpty) {
          _controller.load();
        } else {
          unawaited(_controller.refreshChapter());
        }
      },
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
///
/// 滚到本章最后一张图后继续上滑 → 自动进入下一章（原版
/// `ReadBook.moveToNextChapter` 的行为）。不然看漫画只能先呼出菜单再点「下一章」，
/// 一章一章翻下来非常累。
class _MangaView extends StatefulWidget {
  const _MangaView({
    super.key,
    required this.controller,
    required this.onTapCenter,
    required this.onBoundary,
    required this.textColor,
    this.onImageDoubleTap,
  });

  final ReaderController controller;
  final VoidCallback onTapCenter;
  final ValueChanged<int>? onBoundary;
  final Color textColor;
  final ValueChanged<int>? onImageDoubleTap;

  @override
  State<_MangaView> createState() => _MangaViewState();
}

class _MangaViewState extends State<_MangaView> {
  final ScrollController _scroll = ScrollController();

  /// 每张图的 key：拖进度条时先按比例滚到大致位置，再精确定位到目标图。
  /// 用 map 而不是 list，换章后图片数变化不会留下过期 key。
  final Map<int, GlobalKey> _imageKeys = <int, GlobalKey>{};

  /// 点击判定（见 [ReaderTapTracker]）：上滑后惯性滚动中轻触屏幕只是让它停下，
  /// 不该弹菜单——这与文字章、原版 `ReadView.abortAnim()` 的语义一致。
  final ReaderTapTracker _tap = ReaderTapTracker();

  /// 正文刚刚还在滚动（见 [ReaderScrollViewState._gliding] 的说明）。
  bool _gliding = false;
  Timer? _glideTimer;

  void _markGliding() {
    _gliding = true;
    _glideTimer?.cancel();
    _glideTimer = Timer(const Duration(milliseconds: 150), () {
      if (mounted) _gliding = false;
    });
  }

  late int _chapter = widget.controller.chapterIndex;
  final OverscrollAccumulator _overscroll = OverscrollAccumulator();
  bool _swapping = false;

  /// 正在按 core 记录的章内位置恢复滚动。
  ///
  /// 恢复期间 `_syncImageIndex` 必须停手：ListView 初建在 offset 0，
  /// 第一条滚动通知会把章内位置改写成 0，漫画就永远从第一张开始了。
  bool _restoring = false;

  GlobalKey _keyOf(int index) =>
      _imageKeys.putIfAbsent(index, () => GlobalKey());

  /// 菜单进度条拖动后用章内图片索引定位（不跨章）。
  void scrollToImage(int index) {
    final count = widget.controller.imageCount;
    if (count <= 0 || !_scroll.hasClients) return;
    final target = index.clamp(0, count - 1);
    final max = _scroll.position.maxScrollExtent;
    final offset = max <= 0 ? 0.0 : max * (count <= 1 ? 0 : target / (count - 1));
    unawaited(
      _scroll.animateTo(
        offset,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      ).then((_) {
        final ctx = mounted ? _keyOf(target).currentContext : null;
        if (ctx != null) {
          Scrollable.ensureVisible(
            // ignore: use_build_context_synchronously
            ctx,
            duration: const Duration(milliseconds: 100),
            alignment: 0,
          );
        }
      }),
    );
  }

  /// 按滚动比例估算当前图片：图片高度不等，精确测量需要遍历全部 render object，
  /// 进度条只要求「本章第几张」的大致位置，比例法足够且不会每帧建对象。
  void _syncImageIndex() {
    if (_restoring || !_scroll.hasClients) return;
    final count = widget.controller.imageCount;
    if (count <= 1) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    final ratio = (_scroll.offset / max).clamp(0.0, 1.0);
    widget.controller.noteImageIndex((ratio * (count - 1)).round());
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_syncChapter);
    _restorePosition();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncChapter);
    _glideTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// 续读：滚回本章上次看到的那张图。
  ///
  /// 首帧之后才能滚（那时才有 maxScrollExtent），且图片是边加载边撑高的，
  /// 所以先按比例滚一次、图片陆续到位后再校正一次。
  void _restorePosition() {
    final target = widget.controller.imageIndex;
    if (target <= 0 || widget.controller.imageCount <= 1) return;
    _restoring = true;
    // 两段式：首帧后先滚到大致位置，等图片陆续撑开高度再精确定位一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      scrollToImage(target);
    });
    Timer(const Duration(milliseconds: 350), () {
      if (!mounted || widget.controller.chapterIndex != _chapter) {
        _restoring = false;
        return;
      }
      scrollToImage(target);
      // 恢复期 `_syncImageIndex` 不工作，这里直接把位置写准。
      widget.controller.noteImageIndex(target);
      _restoring = false;
    });
  }

  /// 换章后回到顶部：否则在新章图片还没铺满时，滚动位置会停在上一章的底部。
  void _syncChapter() {
    if (widget.controller.chapterIndex == _chapter) return;
    _chapter = widget.controller.chapterIndex;
    _overscroll.reset();
    // 换章后位置由最新一次 _openChapter 决定（通常从章首开始），恢复态作废。
    _restoring = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    _markGliding();
    if (notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification) {
      _syncImageIndex();
    }
    final dir = _overscroll.accept(notification);
    if (dir != 0) _crossBoundary(dir);
    return false;
  }

  void _crossBoundary(int dir) {
    if (_swapping) return;
    final controller = widget.controller;
    if (controller.chapterLoading) return;
    final hasChapter = dir > 0
        ? controller.hasNextChapter
        : controller.hasPrevChapter;
    _overscroll.reset();
    _swapping = true;
    Timer(const Duration(milliseconds: 400), () => _swapping = false);
    if (!hasChapter) {
      widget.onBoundary?.call(dir);
      return;
    }
    unawaited(dir > 0 ? controller.nextChapter() : controller.prevChapter());
  }

  /// 一次点击的入口：漫画没有分区，单击只切菜单，所以「按停滚动」时什么也不做。
  void _maybeToggleMenu() {
    final abortedGlide = _tap.busyDown;
    if (!_tap.confirm()) return;
    if (abortedGlide) return;
    widget.onTapCenter();
  }

  /// 按下时是否还在惯性滚动。
  bool get _busyAtDown => _gliding;

  @override
  Widget build(BuildContext context) {
    final textColor = widget.textColor;
    return Listener(
      // Listener 不进手势竞技场：单张图自己的 detector 抢走 tap 时，
      // 这里仍能拿到同一份按下/移动数据。
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) => _tap.down(event, busy: _busyAtDown),
      onPointerMove: _tap.move,
      onPointerCancel: _tap.cancel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (_) => _maybeToggleMenu(),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScrollNotification,
          child: ListView.builder(
            controller: _scroll,
            itemCount: widget.controller.images.length,
            // 预取两屏，快速下滑时不至于频繁看到加载骨架。
            cacheExtent: 1200,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemBuilder: (context, index) {
              final url = widget.controller.images[index];
              return _MangaImage(
                key: _keyOf(index),
                url: url,
                localPath: widget.controller.imagePathOf(url),
                index: index,
                textColor: textColor,
                // 下面两个回调共用同一个入口：同一手势只会被确认一次，
                // 不会因为内外两层 detector 都触发而切成「开→关」。
                onTap: _maybeToggleMenu,
                onDoubleTap: widget.onImageDoubleTap == null
                    ? null
                    : () => widget.onImageDoubleTap!(index),
              );
            },
          ),
        ),
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
    super.key,
    required this.url,
    this.localPath,
    required this.index,
    required this.textColor,
    this.onTap,
    this.onDoubleTap,
  });

  final String url;

  /// 内核已缓存的本地图片；有它就不联网（断网也能看漫画）。
  final String? localPath;
  final int index;
  final Color textColor;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    // 大图按屏幕宽度解码，避免整章几十张原图把内存打满。
    final width = MediaQuery.sizeOf(context).width;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (width * dpr).round();

    final image = CachedReaderImage(
      url: url,
      localPath: localPath,
      width: double.infinity,
      fit: BoxFit.fitWidth,
      filterQuality: FilterQuality.medium,
      cacheWidth: cacheWidth > 0 ? cacheWidth : null,
      semanticLabel: '第 ${index + 1} 页',
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) return child;
        return _loading();
      },
      errorBuilder: (context, error, stackTrace) =>
          _failure('第 ${index + 1} 页加载失败'),
    );
    if (onDoubleTap == null && onTap == null) return image;
    // 单击与双击放在同一 detector：双击赢时不发 onTap（不会误弹菜单），
    // 单击则转发给外层的菜单回调，保持原「点哪都弹菜单」的交互。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      child: image,
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
