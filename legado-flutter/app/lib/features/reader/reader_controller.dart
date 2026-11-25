import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/image_url.dart';
import '../../core/shelf_events.dart';
import '../tools/tools_api.dart';
import 'html_text.dart';
import 'pagination.dart';
import 'progress.dart';
import 'reader_style.dart';

/// core 的 `Reader.GetContent.imagePaths` 是「原始 URL → 磁盘绝对路径」。
///
/// UI 查找统一按归一化后的地址（补 `https:`、解 `&amp;`），这样正文 HTML
/// 里的地址和书源返回的图片地址写法不同也能命中同一份缓存。
Map<String, String> parseCachedImagePaths(Object? raw) {
  final paths = <String, String>{};
  if (raw is! Map) return paths;
  raw.forEach((key, value) {
    final normalized = normalizeImageUrl('$key') ?? '$key';
    paths[normalized] = '$value';
  });
  return paths;
}

/// 阅读器数据/排版状态。
///
/// 所有业务数据都来自 core（章节、正文、进度），这里只维护「渲染需要的派生状态」：
/// 段落、分页结果、当前页码。原则是：章节正文只缓存最近几章，
/// 进度只写不读本地——真源始终是 `Reader.GetProgress`。
class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.bookId,
    required this.initialChapter,
    this.initialChapterPos = -1,
    required ReaderStyle style,
    this.initialBookName,
  }) : _style = style;

  final int bookId;

  /// 从书架进入时一般为 -1，表示「按 core 记录的进度续读」。
  final int initialChapter;

  /// 章内位置：文字章是字符偏移，漫画章是第几张图。
  ///
  /// -1 表示「调用方没指定」。书签跳转必须传 —— 只传章节号会落到章首，
  /// 书签等于失效（原版 `Bookmark.readChapter` 会把 `durChapterPos` 一起带过去）。
  final int initialChapterPos;

  final String? initialBookName;

  static const int _maxCachedChapters = 3;

  ReaderStyle _style;
  ReaderStyle get style => _style;

  List<Map<String, dynamic>> _chapters = const [];
  List<Map<String, dynamic>> get chapters => _chapters;

  int _chapterIndex = 0;
  int get chapterIndex => _chapterIndex;

  /// 章节加载请求序号（见 [_openChapter]）：用来丢弃被后续切章取代的响应。
  int _loadToken = 0;

  String _chapterTitle = '';
  String get chapterTitle => _chapterTitle;

  String _bookTitle = '';
  String get bookTitle =>
      _bookTitle.isNotEmpty ? _bookTitle : (initialBookName ?? '阅读');

  /// 书籍地址（网络书是书源详情页，本地书是文件路径）。
  ///
  /// 只有「复制地址」用得到，所以顺手从 `Shelf.GetBook`（本来就要调它取书名）
  /// 里带回来，不为它多发一次请求。
  String _bookUrl = '';
  String get bookUrl => _bookUrl;

  List<String> _paragraphs = const [];

  /// 文字章里的内联图片：下标与 [_paragraphs] 对齐（图片段为空串）。
  Map<int, String> _imageUrls = const {};

  /// 纯图片章（漫画）的地址；文字章即使带图也留空在这里。
  List<String> _images = const [];
  List<PageSlice> _pages = const [];
  int _pageIndex = 0;

  /// 漫画章当前看到第几张图。原版 `ReadManga.durChapterPos`，
  /// 菜单进度条与落盘都按它算章内进度（而不是全书页数）。
  int _imageIndex = 0;

  /// 漫画章的图片地址。core 返回的已是绝对直链；为空表示本章是文字章。
  List<String> get images => _images;

  /// 已落盘的图片：`归一化 URL → 绝对路径`（来自 `Reader.GetContent.imagePaths`）。
  /// 换章时随正文一起替换，绝不跨章复用 —— 不同章的图片文件名按章号分。
  Map<String, String> _imagePaths = const {};

  /// 按图片地址查本地缓存；没有则返回 null，渲染层回落到网络。
  String? imagePathOf(String url) =>
      _imagePaths[normalizeImageUrl(url) ?? url];

  /// 文字章正文里的插图地址（按正文出现顺序）。
  /// 双击插图时用它作为全屏看图的图源列表。
  List<String> get inlineImages =>
      _imageUrls.values.toList(growable: false);

  /// 只有「整章只有图片、没有文字」才按漫画铺开。
  ///
  /// 文字书源（超星等）正文里常夹插图：core 会把这些图也放进 images，
  /// 旧判定会把整章正文替换成图片列表，文字全丢。
  bool get isManga => _images.isNotEmpty && !_hasText;

  bool get _hasText => _paragraphs.any((p) => p.trim().isNotEmpty);

  Size _viewport = Size.zero;
  Size get viewport => _viewport;

  bool _loading = true;
  bool get loading => _loading;

  bool _chapterLoading = false;
  bool get chapterLoading => _chapterLoading;

  bool _hasContent = true;
  bool get hasContent => _hasContent;

  String? _error;
  String? get error => _error;

  final Map<int, _ChapterData> _cache = {};
  final Map<int, Future<_ChapterData>> _inflight = {};

  Timer? _saveTimer;
  int? _savedChapter;
  int? _savedPage;
  bool _closed = false;

  /// 版面还没确定时的目标偏移（窗口尺寸在首帧之后才拿得到）。
  int? _pendingOffset;

  List<PageSlice> get pages => _pages;
  int get pageIndex => _pageIndex;
  int get pageCount => _pages.length;

  /// 漫画章的图片数与当前图片索引（对齐原版 `durChapterPos` / `imageCount`）。
  int get imageCount => _images.length;
  int get imageIndex => _imageIndex;

  /// 由漫画视图滚动时同步；只在真正换图时通知，避免每帧 rebuild 整页。
  void noteImageIndex(int index) {
    if (_images.isEmpty) return;
    final clamped = index.clamp(0, _images.length - 1);
    if (clamped == _imageIndex) return;
    _imageIndex = clamped;
    _scheduleSave();
    notifyListeners();
  }

  PageSlice? get currentPage {
    if (_pages.isEmpty) return null;
    return _pages[_pageIndex.clamp(0, _pages.length - 1)];
  }

  /// 章内进度（0~1）。保存给 core 的 scrollPercent 用的就是这个口径。
  double get chapterPercent => percentForPageIndex(_pages, _pageIndex);

  /// 菜单进度条用的章内进度：首页 0、末页 1。
  ///
  /// 与 [chapterPercent] 的差别是末页：`pageIndex/pageCount` 永远差一格
  /// （12 页读到第 12 页只有 91.7%），进度条拖到最右侧会落不到末页。
  /// 原版 `ReadMenu` 的 seekBar 就是 `max = pageSize - 1` + `progress = durPageIndex`，
  /// 这里按同一口径换算。
  double get chapterReadPercent => readPercentForPageIndex(_pages, _pageIndex);

  /// 全书进度（章节维度）。
  ///
  /// 菜单进度条**不用**它 —— 原版 `progressBarBehavior` 默认是 `"page"`（章内页码），
  /// 全书跳章是另一个可选模式。这里保留是给那个模式与外部（书架进度展示）用。
  double get bookPercent {
    if (_chapters.isEmpty) return 0;
    return ((_chapterIndex + chapterPercent) / _chapters.length).clamp(
      0.0,
      1.0,
    );
  }

  String get chapterLabel =>
      _chapters.isEmpty ? '' : '${_chapterIndex + 1}/${_chapters.length}';

  /// 当前章地址（正文页的 `url`，来自 `Reader.GetChapters`）。
  String get chapterUrl {
    if (_chapterIndex < 0 || _chapterIndex >= _chapters.length) return '';
    return '${_chapters[_chapterIndex]['url'] ?? ''}';
  }

  // ---------------------------------------------------------------- 加载

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final client = LegadoClient.instance;
      // 三个请求互不依赖，并行发出，减少进入阅读器的白屏时间。
      final chaptersFuture = client.callList(Api.readerGetChapters, [bookId]);
      final progressFuture = _readProgress(client);
      final bookFuture = _readBookName(client);

      _chapters = await chaptersFuture;
      final progress = await progressFuture;
      _bookTitle = await bookFuture ?? '';

      if (_chapters.isEmpty) {
        throw const LegadoError('EMPTY_BOOK', '本书没有可用章节');
      }

      var target = initialChapter >= 0
          ? initialChapter
          : (progress?['chapterIndex'] as num?)?.toInt() ?? 0;
      target = target.clamp(0, _chapters.length - 1);
      // 偏移优先级：显式章内位置 > 显式章节（从章首）> core 记录的进度。
      // 指定章节但不指定位置时不能沿用旧偏移，否则会跳到同章后半段。
      final offset = initialChapterPos >= 0
          ? initialChapterPos
          : initialChapter >= 0
          ? 0
          : (progress?['chapterPos'] as num?)?.toInt() ?? 0;

      await _openChapter(target, offset: offset, notifyStart: false);
      _loading = false;
      notifyListeners();
    } on LegadoError catch (e) {
      _error = '${e.code}: ${e.message}';
      _loading = false;
      notifyListeners();
    } catch (e) {
      _error = '$e';
      _loading = false;
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>?> _readProgress(LegadoClient client) async {
    try {
      final data = await client.call(Api.readerGetProgress, [bookId]);
      if (data is Map) return data.cast<String, dynamic>();
      return null;
    } catch (_) {
      // 新书没有进度、或 core 暂时不可用，都不应该阻断打开。
      return null;
    }
  }

  Future<String?> _readBookName(LegadoClient client) async {
    try {
      final data = await client.call(Api.shelfGetBook, [bookId]);
      if (data is Map) {
        // 书名和书籍地址一起带回来（复制地址要用），不额外加一次 RPC。
        _bookUrl = '${data['bookUrl'] ?? ''}';
        return '${data['name'] ?? ''}';
      }
    } catch (_) {
      // 书不在书架也能阅读，书名回落到路由参数。
    }
    return null;
  }

  Future<_ChapterData> _chapterData(int index, {bool refresh = false}) {
    if (refresh) {
      // 手动刷新要连本地内存这一层也掀掉：只让 core 跳过 chapter_cache 不够，
      // 否则 UI 立刻又把 _cache 里的旧正文还回来，看起来像「刷新没生效」。
      _cache.remove(index);
      _inflight.remove(index);
    } else {
      final cached = _cache[index];
      if (cached != null) return Future.value(cached);
      final pending = _inflight[index];
      if (pending != null) return pending;
    }

    final future = _fetchChapter(index, refresh: refresh);
    _inflight[index] = future;
    return future.whenComplete(() => _inflight.remove(index));
  }

  Future<_ChapterData> _fetchChapter(int index, {bool refresh = false}) async {
    final data = await LegadoClient.instance.call(Api.readerGetContent, [
      bookId,
      index,
      // 只有强制刷新才把 true 发过去；平时省略第三参，走 core 的自动缓存。
      if (refresh) true,
    ]);
    final map = data is Map
        ? data.cast<String, dynamic>()
        : <String, dynamic>{};
    final content = HtmlText.toContent('${map['html'] ?? ''}');
    final rawImages = map['images'];
    final images = rawImages is List
        ? rawImages.map((e) => '$e').toList(growable: false)
        : const <String>[];
    final paths = parseCachedImagePaths(map['imagePaths']);
    final result = _ChapterData(
      title: '${map['title'] ?? ''}',
      paragraphs: content.paragraphs,
      imageUrls: content.imageUrls,
      images: images,
      imagePaths: paths,
    );
    _cache[index] = result;
    if (_cache.length > _maxCachedChapters) {
      final removable = _cache.keys
          .where((k) => k != index && k != _chapterIndex)
          .toList(growable: false);
      if (removable.isNotEmpty) _cache.remove(removable.first);
    }
    return result;
  }

  /// 预取相邻章，翻到章末时不至于等一次 RPC。
  void _prefetch(int index) {
    if (index < 0 || index >= _chapters.length || _cache.containsKey(index)) {
      return;
    }
    unawaited(_chapterData(index).then<void>((_) {}, onError: (Object _) {}));
  }

  // ---------------------------------------------------------------- 章节切换

  Future<void> openChapter(int index) => _openChapter(index);

  /// 手动刷新当前章：绕过 app 内存缓存与 core 的 `chapter_cache`，重新联网抓取。
  ///
  /// 用到的场景：书源修正了正文、上次抓到的是防爬占位页、缓存内容本身坏了。
  /// 成功后新正文照常回写缓存（`Reader.GetContent` 抓完就写库），
  /// 也就是说手动刷新是「丢旧缓存 + 重新缓存」而不是「以后都不缓存」。
  ///
  /// 返回是否真的换成了新内容。抓取失败时不清 core 里的缓存，并把内存里
  /// 那一版放回去继续读——总比甩给用户一页错误提示强。
  Future<bool> refreshChapter() async {
    if (_chapters.isEmpty || _chapterLoading) return false;
    final index = _chapterIndex;
    final previous = _cache[index];
    final offset = currentPage?.startOffset ?? 0;

    await _openChapter(index, keepPosition: true, refresh: true);
    if (_error == null) return true;

    if (previous == null) return false;
    _cache[index] = previous;
    await _openChapter(index, offset: offset);
    return false;
  }

  Future<void> nextChapter() async {
    // 跳过卷标题，直接落到下一个正文章节；没有就停在原处。
    final next = _readableFrom(_chapterIndex + 1);
    if (next == null) return;
    await _openChapter(next);
  }

  Future<void> prevChapter() async {
    final previous = _readableBackward(_chapterIndex - 1);
    if (previous == null) return;
    // 上一章落到最后一页，符合「往回翻」的直觉。
    await _openChapter(previous, atEnd: true);
  }

  /// 前后是否还有可读章节。点击翻页到边界时用它区分
  /// 「换章」和「已经是最后一章/第一章」——后者要给提示，否则就是点了没反应。
  bool get hasNextChapter => _readableFrom(_chapterIndex + 1) != null;
  bool get hasPrevChapter => _readableBackward(_chapterIndex - 1) != null;

  int? _readableFrom(int start) {
    for (var i = start; i < _chapters.length; i++) {
      if (_chapters[i]['isVolume'] != true) return i;
    }
    return null;
  }

  int? _readableBackward(int start) {
    for (var i = start; i >= 0; i--) {
      if (_chapters[i]['isVolume'] != true) return i;
    }
    return null;
  }

  /// 卷标题不是可读章节：落到卷上时自动找最近的正文章节，
  /// 否则 core 会返回空正文，用户看到「本章暂无正文」。
  int _readableIndex(int index) {
    return _readableFrom(index) ?? _readableBackward(index) ?? index;
  }

  Future<void> _openChapter(
    int index, {
    int offset = 0,
    bool atEnd = false,
    bool notifyStart = true,
    bool refresh = false,
    bool keepPosition = false,
  }) async {
    if (_chapters.isEmpty) return;
    final target = _readableIndex(index.clamp(0, _chapters.length - 1));

    // 请求令牌：连续点「下一章」时会有多个请求在飞，慢的那个后返回。
    // 没有令牌就会把旧章的正文/图片写进当前章（表现为「翻了两章却停在上一章」）。
    final token = ++_loadToken;

    // 切章前先把上一章的位置落盘，避免「退出后回到更早的位置」。
    if (_pages.isNotEmpty) await saveProgress(force: true);
    if (token != _loadToken) return;

    final chapter = _chapters[target];
    final fallbackTitle = '${chapter['title'] ?? ''}';
    _chapterIndex = target;
    // 标题先不落到 _chapterTitle：正文还没到，页脚/菜单仍显示上一章，
    // 等数据回来再一起切换，避免「新标题 + 旧正文」的错位闪动。
    _chapterLoading = true;
    _error = null;
    if (notifyStart) notifyListeners();

    var loaded = false;
    try {
      final data = await _chapterData(target, refresh: refresh);
      // 已经被更新的切章请求取代：丢掉这次结果，连错误态也不写。
      if (token != _loadToken) return;
      _paragraphs = data.paragraphs;
      _imageUrls = data.imageUrls;
      _images = data.images;
      _imagePaths = data.imagePaths;
      _hasContent =
          _paragraphs.any((p) => p.trim().isNotEmpty) ||
          _imageUrls.isNotEmpty ||
          _images.isNotEmpty;
      // 漫画章把 core 的 chapterPos 当图片索引恢复；文字章归零。
      // 原版 ReadManga 也是用 durChapterPos 记章内第几张图。
      _imageIndex = isManga
          ? offset.clamp(0, _images.isEmpty ? 0 : _images.length - 1)
          : 0;
      _chapterTitle = data.title.isNotEmpty ? data.title : fallbackTitle;
      // keepPosition：刷新当前章时停在原来那句话附近。
      // 传 null 让 _repaginate 回落到 currentPage.startOffset（此时还是旧分页）。
      _repaginate(
        targetOffset: (atEnd || keepPosition) ? null : offset,
        atEnd: atEnd,
      );
      loaded = true;
    } on LegadoError catch (e) {
      if (token != _loadToken) return;
      _paragraphs = const [];
      _imageUrls = const {};
      _images = const [];
      _imagePaths = const {};
      _pages = const [];
      _hasContent = false;
      _error = '${e.code}: ${e.message}';
    } catch (e) {
      if (token != _loadToken) return;
      // 传输层异常（core 掉线、JSON 解析失败等）也要落到错误态，
      // 否则会停在「上一章内容 + 进度条" 的半截状态。
      _paragraphs = const [];
      _imageUrls = const {};
      _images = const [];
      _imagePaths = const {};
      _pages = const [];
      _hasContent = false;
      _error = '$e';
    } finally {
      // 只有最新的请求有权清掉 loading：过期的请求把 loading 归零会让 UI
      // 以为当前章已经加载完，显示空白页。
      if (token == _loadToken) {
        _chapterLoading = false;
        notifyListeners();
      }
    }

    // 加载失败时不能保存：此时页码是 0、标题还是上一章的，写进去会污染进度。
    if (loaded) {
      _prefetch(target + 1);
      _prefetch(target - 1);
      _scheduleSave();
      // 阅读记录：每次成功打开一章记一条，core 按「同书同日同章」去重并
      // 刷新时间。之前 core 的 Record.Append 已实现却全仓零调用，阅读记录
      // 页因此永远是空的。fire-and-forget，失败不影响阅读。
      unawaited(_recordRead(target));
    }
  }

  Future<void> _recordRead(int index) async {
    try {
      await ToolsApi.recordAppend(
        bookId: bookId,
        bookName: bookTitle,
        chapterIndex: index,
        chapterTitle: _chapterTitle,
      );
    } catch (_) {
      // 统计失败不影响阅读。
    }
  }

  // ---------------------------------------------------------------- 分页

  /// 首帧拿到视口后调用。
  ///
  /// 允许在 build 阶段直接调用（内部刻意不 notify），否则只能靠
  /// post-frame 回调补一帧，会先闪一页空内容。
  void ensureLayout(Size size) {
    if (_viewport == size) return;
    _viewport = size;
    if (_paragraphs.isEmpty && _imageUrls.isEmpty) {
      _pages = const [];
      _pageIndex = 0;
      return;
    }
    _repaginate();
  }

  void _repaginate({int? targetOffset, bool atEnd = false}) {
    final boundary =
        targetOffset ?? _pendingOffset ?? currentPage?.startOffset ?? 0;
    _pendingOffset = boundary;
    if (_viewport.isEmpty) {
      _pages = const [];
      _pageIndex = 0;
      return;
    }
    _pages = paginate(
      paragraphs: _paragraphs,
      pageSize: _style.contentSize(_viewport),
      typography: _style.typography,
      imageUrls: _imageUrls,
    );
    _pageIndex = atEnd
        ? _pages.length - 1
        : pageIndexForOffset(_pages, boundary);
    _pendingOffset = null;
  }

  void applyStyle(ReaderStyle next) {
    _style = next;
    // 不改这里的分页逻辑：段距/缩进/对齐都可能变，必须整章重排。
    if (_paragraphs.isNotEmpty || _imageUrls.isNotEmpty) _repaginate();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 翻页

  PageSlice? neighborPage(int delta) {
    final target = _pageIndex + delta;
    if (target < 0 || target >= _pages.length) return null;
    return _pages[target];
  }

  Future<void> turnPage(int delta) async {
    if (_chapterLoading || _pages.isEmpty) return;
    final target = _pageIndex + delta;
    if (target < 0) {
      await prevChapter();
      return;
    }
    if (target >= _pages.length) {
      await nextChapter();
      return;
    }
    _pageIndex = target;
    notifyListeners();
    _scheduleSave();
  }

  /// 滚动模式用：滚动过程中只更新页码，不 notify（否则会重建 ListView 造成抖动）。
  void noteScrollPage(int index) {
    if (_pages.isEmpty) return;
    final clamped = index.clamp(0, _pages.length - 1);
    if (clamped == _pageIndex) return;
    _pageIndex = clamped;
    _scheduleSave();
  }

  /// 跳到本章第 [index] 页（菜单进度条拖动用）。
  ///
  /// 只在章内跳，不跨章：原版进度条默认行为（`progressBarBehavior = "page"`）
  /// 就是 `ReadBook.skipToPage`，全书跳章是另一个可选项，不在默认路径上。
  void jumpToPage(int index) {
    if (_pages.isEmpty) return;
    final clamped = index.clamp(0, _pages.length - 1);
    if (clamped == _pageIndex) {
      // 页码没变也要 notify：进度条松手后要把临时值清掉重画。
      notifyListeners();
      return;
    }
    _pageIndex = clamped;
    notifyListeners();
    _scheduleSave();
  }

  // ---------------------------------------------------------------- 进度

  void _scheduleSave() {
    if (_closed) return;
    _saveTimer?.cancel();
    // 1s 防抖：连续翻页只在停下来之后写一次，避免每页一次 RPC。
    _saveTimer = Timer(const Duration(seconds: 1), () => saveProgress());
  }

  Future<void> saveProgress({bool force = false}) async {
    if (_closed) return;
    if (_chapters.isEmpty || _chapterIndex >= _chapters.length) return;
    // 正文没加载成功（pages 与 images 都空）时没有可信位置，不要覆盖旧进度。
    if (_pages.isEmpty && _images.isEmpty) return;
    if (!force && _savedChapter == _chapterIndex && _savedPage == _pageIndex) {
      return;
    }

    _saveTimer?.cancel();
    final chapterIndex = _chapterIndex;
    final manga = isManga;
    // 漫画章记「第几张图」（原版 durChapterPos），文字章记「第几页」。
    // 两者都落在 core 的 chapterPos 字段里，按章类型解释。
    final page = manga ? _imageIndex : _pageIndex;
    final position = manga
        ? _imageIndex
        : currentPage?.startOffset ?? 0;
    // core 的 scrollPercent 口径是 0~100（见 domain/book.go），内部计算保持 0~1。
    final scrollPercent = (manga
            ? readPercentForIndex(_imageIndex, _images.length)
            : chapterPercent) *
        100;
    try {
      await LegadoClient.instance.call(Api.readerSaveProgress, [
        bookId,
        chapterIndex,
        _chapterTitle,
        position,
        scrollPercent,
      ]);
      _savedChapter = chapterIndex;
      _savedPage = page;
    } catch (_) {
      // 保存失败不打断阅读；下一次翻页/退出会再试。
    }
  }

  // ---------------------------------------------------------------- 朗读

  /// 把当前页交给 core 切成朗读片段。
  /// 音频引擎还没接，这里只验证 `Tts.Segment` 链路并给用户预览。
  Future<List<Map<String, dynamic>>> segmentCurrentPage() async {
    final text = currentPage?.text ?? '';
    if (text.isEmpty) return const [];
    // 位置参数：core 的信封是 {"method":..,"args":[..]}，参数名只存在于
    // Go 侧的 Sig 声明里（`Tts.Segment(text string, maxRunes int)`）。
    return LegadoClient.instance.callList(Api.ttsSegment, [text, 120]);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    // 退出阅读器时兜底保存一次。saveProgress 会在首个 await 前读完当前状态，
    // 所以这里先把请求发出去，再把 _closed 置位（否则会被自身的守卫拦掉）。
    unawaited(_saveBeforeExit());
    _closed = true;
    super.dispose();
  }

  /// 退出前落盘，落完再广播一次书架变更。
  ///
  /// 书架页常驻在 IndexedStack 里、只在 initState 拉一次数据，不通知的话
  /// 读完一本书回到书架，进度还停在打开前的样子（原版靠 Room Flow 自动刷新）。
  /// 广播必须等 RPC 返回，否则书架重拉时读到的还是旧进度。
  Future<void> _saveBeforeExit() async {
    try {
      await saveProgress(force: true);
    } finally {
      ShelfEvents.changed();
    }
  }
}

class _ChapterData {
  const _ChapterData({
    required this.title,
    required this.paragraphs,
    required this.imageUrls,
    required this.images,
    this.imagePaths = const {},
  });

  final String title;
  final List<String> paragraphs;
  final Map<int, String> imageUrls;
  final List<String> images;
  final Map<String, String> imagePaths;
}
