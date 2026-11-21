import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import 'html_text.dart';
import 'pagination.dart';
import 'reader_style.dart';

/// 阅读器数据/排版状态。
///
/// 所有业务数据都来自 core（章节、正文、进度），这里只维护「渲染需要的派生状态」：
/// 段落、分页结果、当前页码。原则是：章节正文只缓存最近几章，
/// 进度只写不读本地——真源始终是 `Reader.GetProgress`。
class ReaderController extends ChangeNotifier {
  ReaderController({
    required this.bookId,
    required this.initialChapter,
    required ReaderStyle style,
    this.initialBookName,
  }) : _style = style;

  final int bookId;

  /// 从书架进入时一般为 -1，表示「按 core 记录的进度续读」。
  final int initialChapter;

  final String? initialBookName;

  static const int _maxCachedChapters = 3;

  ReaderStyle _style;
  ReaderStyle get style => _style;

  List<Map<String, dynamic>> _chapters = const [];
  List<Map<String, dynamic>> get chapters => _chapters;

  int _chapterIndex = 0;
  int get chapterIndex => _chapterIndex;

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

  /// 漫画章的图片地址。core 返回的已是绝对直链，UI 直接交给 `Image.network`；
  /// 为空表示本章是文字章。
  List<String> get images => _images;

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

  PageSlice? get currentPage {
    if (_pages.isEmpty) return null;
    return _pages[_pageIndex.clamp(0, _pages.length - 1)];
  }

  /// 章内进度（0~1）。保存给 core 的 scrollPercent 用的就是这个口径。
  double get chapterPercent => percentForPageIndex(_pages, _pageIndex);

  /// 全书进度（章节维度）。菜单里的进度条用它。
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
      // 指定章节进入时不沿用旧章节的字符偏移，否则会跳到同章后半段。
      final offset = initialChapter >= 0
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
    final result = _ChapterData(
      title: '${map['title'] ?? ''}',
      paragraphs: content.paragraphs,
      imageUrls: content.imageUrls,
      images: images,
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

    // 切章前先把上一章的位置落盘，避免「退出后回到更早的位置」。
    if (_pages.isNotEmpty) await saveProgress(force: true);

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
      _paragraphs = data.paragraphs;
      _imageUrls = data.imageUrls;
      _images = data.images;
      _hasContent =
          _paragraphs.any((p) => p.trim().isNotEmpty) ||
          _imageUrls.isNotEmpty ||
          _images.isNotEmpty;
      _chapterTitle = data.title.isNotEmpty ? data.title : fallbackTitle;
      // keepPosition：刷新当前章时停在原来那句话附近。
      // 传 null 让 _repaginate 回落到 currentPage.startOffset（此时还是旧分页）。
      _repaginate(
        targetOffset: (atEnd || keepPosition) ? null : offset,
        atEnd: atEnd,
      );
      loaded = true;
    } on LegadoError catch (e) {
      _paragraphs = const [];
      _imageUrls = const {};
      _images = const [];
      _pages = const [];
      _hasContent = false;
      _error = '${e.code}: ${e.message}';
    } catch (e) {
      // 传输层异常（core 掉线、JSON 解析失败等）也要落到错误态，
      // 否则会停在「上一章内容 + 进度条" 的半截状态。
      _paragraphs = const [];
      _imageUrls = const {};
      _images = const [];
      _pages = const [];
      _hasContent = false;
      _error = '$e';
    } finally {
      _chapterLoading = false;
      notifyListeners();
    }

    // 加载失败时不能保存：此时页码是 0、标题还是上一章的，写进去会污染进度。
    if (loaded) {
      _prefetch(target + 1);
      _prefetch(target - 1);
      _scheduleSave();
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
    final page = _pageIndex;
    final position = currentPage?.startOffset ?? 0;
    // core 的 scrollPercent 口径是 0~100（见 domain/book.go），内部计算保持 0~1。
    final scrollPercent = chapterPercent * 100;
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
    unawaited(saveProgress(force: true));
    _closed = true;
    super.dispose();
  }
}

class _ChapterData {
  const _ChapterData({
    required this.title,
    required this.paragraphs,
    required this.imageUrls,
    required this.images,
  });

  final String title;
  final List<String> paragraphs;
  final Map<int, String> imageUrls;
  final List<String> images;
}
