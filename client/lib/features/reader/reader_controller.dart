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
  String get bookTitle => _bookTitle.isNotEmpty ? _bookTitle : (initialBookName ?? '阅读');

  List<String> _paragraphs = const [];
  List<String> _images = const [];
  List<PageSlice> _pages = const [];
  int _pageIndex = 0;

  /// 漫画章的图片地址。core 的 `/img` 数据面还没接，UI 只用它渲染占位框。
  List<String> get images => _images;

  bool get isManga => _images.isNotEmpty;

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
    return ((_chapterIndex + chapterPercent) / _chapters.length).clamp(0.0, 1.0);
  }

  String get chapterLabel =>
      _chapters.isEmpty ? '' : '${_chapterIndex + 1}/${_chapters.length}';

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
      final offset = initialChapter >= 0 ? 0 : (progress?['chapterPos'] as num?)?.toInt() ?? 0;

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
      if (data is Map) return '${data['name'] ?? ''}';
    } catch (_) {
      // 书不在书架也能阅读，书名回落到路由参数。
    }
    return null;
  }

  Future<_ChapterData> _chapterData(int index) {
    final cached = _cache[index];
    if (cached != null) return Future.value(cached);
    final pending = _inflight[index];
    if (pending != null) return pending;

    final future = _fetchChapter(index);
    _inflight[index] = future;
    return future.whenComplete(() => _inflight.remove(index));
  }

  Future<_ChapterData> _fetchChapter(int index) async {
    final data = await LegadoClient.instance.call(Api.readerGetContent, [bookId, index]);
    final map = data is Map ? data.cast<String, dynamic>() : <String, dynamic>{};
    final paragraphs = HtmlText.toParagraphs('${map['html'] ?? ''}');
    final rawImages = map['images'];
    final images = rawImages is List
        ? rawImages.map((e) => '$e').toList(growable: false)
        : const <String>[];
    final result = _ChapterData(
      title: '${map['title'] ?? ''}',
      paragraphs: paragraphs,
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
    if (index < 0 || index >= _chapters.length || _cache.containsKey(index)) return;
    unawaited(_chapterData(index).then<void>((_) {}, onError: (Object _) {}));
  }

  // ---------------------------------------------------------------- 章节切换

  Future<void> openChapter(int index) => _openChapter(index);

  Future<void> nextChapter() async {
    if (_chapterIndex + 1 >= _chapters.length) return;
    await _openChapter(_chapterIndex + 1);
  }

  Future<void> prevChapter() async {
    if (_chapterIndex <= 0) return;
    // 上一章落到最后一页，符合「往回翻」的直觉。
    await _openChapter(_chapterIndex - 1, atEnd: true);
  }

  Future<void> _openChapter(
    int index, {
    int offset = 0,
    bool atEnd = false,
    bool notifyStart = true,
  }) async {
    if (_chapters.isEmpty) return;
    final target = index.clamp(0, _chapters.length - 1);

    // 切章前先把上一章的位置落盘，避免「退出后回到更早的位置」。
    if (_pages.isNotEmpty) await saveProgress(force: true);

    final chapter = _chapters[target];
    _chapterIndex = target;
    _chapterTitle = '${chapter['title'] ?? ''}';
    _chapterLoading = true;
    _error = null;
    if (notifyStart) notifyListeners();

    try {
      final data = await _chapterData(target);
      _paragraphs = data.paragraphs;
      _images = data.images;
      _hasContent = data.paragraphs.any((p) => p.trim().isNotEmpty) || data.images.isNotEmpty;
      if (data.title.isNotEmpty) _chapterTitle = data.title;
      _repaginate(targetOffset: atEnd ? null : offset, atEnd: atEnd);
    } on LegadoError catch (e) {
      _paragraphs = const [];
      _images = const [];
      _pages = const [];
      _hasContent = false;
      _error = '${e.code}: ${e.message}';
    } catch (e) {
      // 传输层异常（core 掉线、JSON 解析失败等）也要落到错误态，
      // 否则会停在「上一章内容 + 进度条" 的半截状态。
      _paragraphs = const [];
      _images = const [];
      _pages = const [];
      _hasContent = false;
      _error = '$e';
    } finally {
      _chapterLoading = false;
      notifyListeners();
    }

    _prefetch(target + 1);
    _prefetch(target - 1);
    _scheduleSave();
  }

  // ---------------------------------------------------------------- 分页

  /// 首帧拿到视口后调用。
  ///
  /// 允许在 build 阶段直接调用（内部刻意不 notify），否则只能靠
  /// post-frame 回调补一帧，会先闪一页空内容。
  void ensureLayout(Size size) {
    if (_viewport == size) return;
    _viewport = size;
    if (_paragraphs.isEmpty) {
      _pages = const [];
      _pageIndex = 0;
      return;
    }
    _repaginate();
  }

  void _repaginate({int? targetOffset, bool atEnd = false}) {
    final boundary = targetOffset ?? _pendingOffset ?? currentPage?.startOffset ?? 0;
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
    );
    _pageIndex = atEnd ? _pages.length - 1 : pageIndexForOffset(_pages, boundary);
    _pendingOffset = null;
  }

  void applyStyle(ReaderStyle next) {
    _style = next;
    ReaderStyleStore.save(next);
    if (_paragraphs.isNotEmpty) _repaginate();
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
    if (!force && _savedChapter == _chapterIndex && _savedPage == _pageIndex) return;

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
    return LegadoClient.instance.callList(Api.ttsSegment, [
      {'text': text, 'maxRunes': 120},
    ]);
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
  const _ChapterData({required this.title, required this.paragraphs, required this.images});

  final String title;
  final List<String> paragraphs;
  final List<String> images;
}
