import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/domain.dart';
import '../../format/comic_parser.dart';
import '../../format/format.dart';
import '../../format/text_codec.dart';
import '../../format/txt_parser.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/store.dart';
import '../cache/image_cache_service.dart';
import '../replacerule/replacement_processor.dart';
import '../setting/settings_service.dart';
import '../shelf/shelf_service.dart';
import '../source/source_fetch_service.dart';

/// 阅读器服务：目录、正文、进度与大纲回写。
///
/// 进度刻意委托 [ShelfService]：阅读器和书架列表必须写同一份 position，
/// 否则「阅读器说读到第 3 章、书架显示 12%」这种错位会非常难查。
class ReaderService {
  ReaderService({
    required StoreDaos daos,
    required ShelfService shelf,
    SourceFetchService? sourceFetch,
    SettingsService? settings,
    ImageCacheService? images,
    String homeDir = '',
  })  : _daos = daos,
        _shelf = shelf,
        _sourceFetch = sourceFetch,
        _settings = settings,
        // homeDir 为空（部分 CLI/单测）时不建图片缓存：否则会把图片写到
        // 进程当前目录的 cache/ 下，测试跑完留一地垃圾。
        _images = images ?? (homeDir.isEmpty ? null : ImageCacheService(homeDir: homeDir)),
        _homeDir = homeDir;

  final StoreDaos _daos;
  final ShelfService _shelf;

  /// 设置域；为 null（CLI/测试未装配设置域）时用下面的内置默认值。
  final SettingsService? _settings;

  /// 数据目录：本地漫画解压出的图片缓存在 `<home>/cache/comic/<bookId>`。
  final String _homeDir;

  /// 网络书正文抓取链路；为 null 时只支持本地书。
  final SourceFetchService? _sourceFetch;

  /// 图片磁盘缓存；由 ReaderModule 创建并与 CacheService 共享同一个实例
  /// （共享下载闸门与 cookie），CLI/单测未给 homeDir 时为 null。
  final ImageCacheService? _images;

  /// 自动缓存的偏好值（键在 `settings/setting_schema.dart`）。
  bool get _autoCache =>
      (_settings?.value('cache.autoCache') ?? 'true') == 'true';

  /// 预取章节数：当前章之后自动缓存多少章。0 只缓存读过的章。
  int get _preDownloadNum =>
      int.tryParse(_settings?.value('cache.preDownloadNum') ?? '10') ?? 10;

  /// 缓存有效期（天）。0 = 永不过期（原版行为）。
  int get _cacheExpireDays =>
      int.tryParse(_settings?.value('cache.expireDays') ?? '0') ?? 0;

  /// 替换净化（正文与标题都过一遍，口径与网络书一致）。
  late final ReplacementProcessor _replacer =
      ReplacementProcessor(_daos.replaceRule);

  ReplacementTarget _targetOf(Book book) =>
      ReplacementTarget(bookName: book.name, origin: book.origin);

  static const HtmlEscape _escape = HtmlEscape();

  List<Map<String, Object?>> getChapters(int bookId) {
    final book = _requireBook(bookId);
    // 自愈：历史数据里 index 可能有空洞（见 BookChapterDao.renumberIfNeeded），
    // 前端一律按列表下标取章节，序号不连续就会跳到错误的章。
    _daos.chapter.renumberIfNeeded(book.bookUrl);
    return [
      for (final chapter in _daos.chapter.getChapterList(book.bookUrl))
        <String, Object?>{
          'index': chapter.index,
          'title': _normalizeTitle(chapter.title),
          'url': chapter.url,
          'isVolume': chapter.isVolume,
          // 付费/VIP 标记：目录里要给用户看得出哪章要买、哪章要会员，
          // 否则点进去只看到空正文会以为是书源坏了。
          if (chapter.isVip) 'isVip': true,
          if (chapter.isPay) 'isPay': true,
          if (book.type & BookType.audio != 0 && chapter.end != null)
            'duration': chapter.end,
        },
    ];
  }

  /// 取正文。
  ///
  /// 本地书按「书 + 章节序号」从源文件读；网络书先查离线缓存，未命中才走书源抓取。
  /// 抓到的新章节会按设置自动入库（`cache.autoCache`），并预取后续若干章。
  ///
  /// [refresh] 为 true 时跳过缓存强制联网（缓存管理页的「重新缓存」用）。
  ///
  /// [downloadImages] 只给缓存任务关掉：缓存任务会自己 await 图片下载并计入
  /// job 进度，这里再下一遍会重复占带宽。UI/预取保持默认 true —— 原版
  /// `ImageProvider.cacheImage` 也是「读到哪、图片存到哪」。
  Future<Map<String, Object?>> getContent(
    int bookId,
    int index, {
    bool refresh = false,
    bool downloadImages = true,
  }) async {
    if (index < 0) {
      throw const LegadoException(ErrorCode.invalid, '章节序号不能为负');
    }
    final book = _requireBook(bookId);
    final chapter = _daos.chapter.getChapter(book.bookUrl, index);
    if (chapter == null) {
      throw LegadoException(ErrorCode.notFound, '章节不存在: $index');
    }
    final total = book.totalChapterNum > 0
        ? book.totalChapterNum
        : _daos.chapter.getChapterCount(book.bookUrl);
    _purgeExpiredCacheIfNeeded();

    String html;
    List<String> images;
    String? fetchedTitle;
    var titleFromCache = false;
    final cached = refresh ? null : _cacheHit(book, chapter);
    if (cached != null) {
      html = cached.html;
      images = _decodeImages(cached.images);
      fetchedTitle = cached.title.trim().isEmpty ? null : cached.title;
      titleFromCache = fetchedTitle != null;
      // 老缓存只有地址没有图片：这次先照常显示网络图，同时后台补齐磁盘文件，
      // 下次进章就能离线看。不能因此判定缓存未命中 —— 那会让每次翻章都重抓正文。
      if (downloadImages && images.isNotEmpty) {
        final cache = _images;
        if (cache != null && !cache.hasAllImages(bookId, index, images)) {
          unawaited(cache.downloadChapter(bookId, index, images));
        }
      }
    } else {
      (String, List<String>, String?) rawContent;
      try {
        rawContent = await _contentOf(book, chapter);
      } on LegadoException catch (e) {
        // 付费/VIP 章抓不到正文是常态（书源本来就不给），别把「解析不出内容」
        // 直接抛给用户当成故障；给一句说明，配上目录里的付费标记。
        final paid = chapter.isPay || chapter.isVip;
        if (!paid || e.code != ErrorCode.invalid) rethrow;
        rawContent = (
          '<p>本章为${chapter.isPay ? '付费' : 'VIP'}章节，书源未提供正文。</p>',
          const <String>[],
          null,
        );
      }
      (html, images, fetchedTitle) = rawContent;
      // refresh=true 是「用户明确要求重抓」（阅读器刷新正文、缓存管理页的
      // Cache.Start），这类写入不受 cache.autoCache 约束，否则关掉自动缓存后
      // 手动缓存会一直显示不出进度、下次读又回落到旧内容。
      _autoCacheChapter(
        bookId,
        book,
        chapter,
        html,
        images,
        fetchedTitle,
        force: refresh,
        downloadImages: downloadImages,
      );
      _schedulePrefetch(book, index, total);
    }

    // `ruleContent.title`：标题只在正文页才完整的源（目录里是「第1章」或空串）。
    // 解出来就回写 chapters.title，下一次打开目录/翻页都直接是正确标题。
    //
    // **缓存命中的标题不回写**：它只是上次抓取时的快照，而目录可能已经被
    // 「更新目录」刷成了新标题（作者改了章节名、站点补了卷名）。拿旧快照覆盖
    // 会把目录标题改回去并落库，表现为「更新目录后标题又变回来了」。
    var chapterTitle = chapter.title;
    if (!titleFromCache &&
        fetchedTitle != null &&
        fetchedTitle.trim().isNotEmpty &&
        fetchedTitle.trim() != chapter.title) {
      chapterTitle = fetchedTitle.trim();
      chapter.title = chapterTitle;
      _daos.chapter.update(chapter);
    }

    return <String, Object?>{
      'bookId': bookId,
      'index': index,
      'title': _replacer.title(_normalizeTitle(chapterTitle), _targetOf(book)),
      'html': html,
      'images': images,
      // 已落盘的图片：原始 URL → 绝对路径。UI 本地优先、网络兜底；
      // 只返回存在的文件，缓存还没下完时自然回落到 Image.network。
      'imagePaths': _images?.cachedPaths(bookId, index, images) ??
          <String, String>{},
      if (cached != null) 'fromCache': true,
      if (chapter.isVip) 'isVip': true,
      if (chapter.isPay) 'isPay': true,
      'prevIndex': index > 0 ? index - 1 : -1,
      'nextIndex': index + 1 < total ? index + 1 : -1,
      'totalChapters': total,
    };
  }

  /// 取本地书的源文件绝对路径。
  ///
  /// 供 UI 做内核做不了的平台级渲染（PDF 逐页渲染、漫画原图）。
  /// 网络书没有本地文件，返回空串。
  String getLocalFilePath(int bookId) {
    final book = _requireBook(bookId);
    return book.isLocal ? book.bookUrl : '';
  }

  /// 取本地漫画的某一页：解压到缓存目录并返回文件路径。
  ///
  /// 为什么返回路径而不是字节：一页漫画动辄 1~2MB，走 JSON 控制面要 base64
  /// 膨胀 33%，还会把整页塞进内存。落盘后 UI 直接用 `Image.file` 读，
  /// 相邻页的预加载也交给 Flutter 的图片缓存。
  ///
  /// zip 每次都要重新解析（没有持久化索引）。这是有意的折中：解析 800 页
  /// 的 zip 约 100~300ms，而缓存失效/换文件带来的「读到旧页」更难排查。
  Future<Map<String, Object?>> getLocalPage(int bookId, int index) async {
    if (index < 0) {
      throw const LegadoException(ErrorCode.invalid, '页码不能为负');
    }
    final book = _requireBook(bookId);
    if (!book.isLocal) {
      throw const LegadoException(
        ErrorCode.invalid,
        '网络漫画请通过 Reader.GetContent 的 images 渲染',
      );
    }
    final file = File(book.bookUrl);
    if (!file.existsSync()) {
      throw LegadoException(
        ErrorCode.notFound,
        '本地书源文件不存在: ${book.bookUrl}',
      );
    }
    final parsed = await BookParser.parse(
      await file.readAsBytes(),
      fileName: p.basename(book.bookUrl),
      charset: book.charset,
    );
    if (parsed.format != BookFormat.comic) {
      throw LegadoException(
        ErrorCode.invalid,
        '该文件不是漫画包（zip/cbz）: ${book.bookUrl}',
      );
    }
    if (index >= parsed.pages.length) {
      throw LegadoException(
        ErrorCode.notFound,
        '页码超出范围: $index / ${parsed.pages.length}',
      );
    }
    final page = parsed.pages[index];
    final bytes = page.bytes();
    if (bytes.isEmpty) {
      throw LegadoException(ErrorCode.internal, '第 ${index + 1} 页解压为空');
    }
    final ext = _imageExtension(page.name);
    final dir = Directory(p.join(_homeDir, 'cache', 'comic', '$bookId'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final target = File(p.join(dir.path, '${index + 1}.$ext'));
    // 长度相同就复用：漫画页内容几乎不会变，重复写盘只会拖慢翻页。
    if (!target.existsSync() || target.lengthSync() != bytes.length) {
      await target.writeAsBytes(bytes, flush: true);
    }
    return <String, Object?>{
      'index': index,
      'pageCount': parsed.pages.length,
      'name': page.name,
      'path': target.path,
      'mime': _imageMime(ext),
    };
  }

  /// 图片扩展名（小写，不含点）；不认识的按 jpg 存，Flutter 按内容也能解。
  static String _imageExtension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'jpg';
    final ext = name.substring(dot + 1).toLowerCase();
    return ComicParser.imageExtensions.contains(ext) ? ext : 'jpg';
  }

  static String _imageMime(String ext) => switch (ext) {
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'bmp' => 'image/bmp',
        'avif' => 'image/avif',
        'heic' => 'image/heic',
        _ => 'image/jpeg',
      };

  Map<String, Object?> getProgress(int bookId) => _shelf.getProgress(bookId);

  void saveProgress(
    int bookId,
    int chapterIndex,
    String chapterTitle,
    int chapterPos,
    double scrollPercent,
  ) =>
      _shelf.saveProgress(
        bookId,
        chapterIndex,
        chapterTitle,
        chapterPos,
        scrollPercent,
      );

  /// 前端解析出的目录回写（PDF 大纲 / 页数，或修正 txt 自动分章）。
  void syncOutline(int bookId, List<Object?> items) {
    if (items.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '目录不能为空');
    }
    final book = _requireBook(bookId);
    final chapters = <BookChapter>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is! Map) {
        throw LegadoException(
          ErrorCode.invalid,
          '第 $i 个目录项不是对象: ${item.runtimeType}',
        );
      }
      final url = '${item['url'] ?? ''}';
      final duration = item['duration'];
      chapters.add(
        BookChapter(
          url: url.isNotEmpty ? url : '${book.bookUrl}#outline-$i',
          bookUrl: book.bookUrl,
          index: i,
          title: _normalizeTitle('${item['title'] ?? ''}'),
          isVolume: item['isVolume'] == true,
          end: duration is num ? duration.toInt() : null,
        ),
      );
    }
    runInTransaction(_daos.db, () {
      _daos.chapter.deleteByBookUrl(book.bookUrl);
      // 逐条 insert 而不是 insertAll：后者自己也会 BEGIN，事务不能嵌套。
      for (final chapter in chapters) {
        _daos.chapter.insert(chapter);
      }
    });
    book
      ..totalChapterNum = chapters.length
      ..lastCheckTime = DateTime.now().millisecondsSinceEpoch;
    _daos.book.update(book);
  }

  // ----------------------------------------------------------------------

  Book _requireBook(int bookId) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }
    return book;
  }

  Future<(String, List<String>, String?)> _contentOf(
    Book book,
    BookChapter chapter,
  ) async {
    if (chapter.isVolume) return ('', const <String>[], null);
    if (!book.isLocal) {
      // 网络书：走书源抓取链路的正文规则。
      final fetch = _sourceFetch;
      if (fetch == null) {
        throw const LegadoException(
          ErrorCode.notImplemented,
          '网络书正文抓取链路未接入',
        );
      }
      final source = fetch.sourceByUrl(book.origin);
      if (source == null) {
        throw LegadoException(
          ErrorCode.notFound,
          '书源不存在: ${book.origin}',
        );
      }
      // 下一章地址作为翻页边界：nextContentUrl 追页时遇到它就停，
      // 避免把「下一章」误当成当前章的分页（对齐 Kotlin setNextChapterUrl）。
      final nextChapterUrl =
          _daos.chapter.getChapter(book.bookUrl, chapter.index + 1)?.url ??
          _daos.chapter.getChapter(book.bookUrl, 0)?.url;
      final fetched = await fetch.fetchContent(
        source,
        book.bookUrl,
        chapter.url,
        chapterTitle: chapter.title,
        nextChapterUrl: nextChapterUrl,
      );
      return (fetched.html, fetched.images, fetched.title);
    }
    final file = File(book.bookUrl);
    if (!file.existsSync()) {
      throw LegadoException(
        ErrorCode.notFound,
        '本地书源文件不存在: ${book.bookUrl}',
      );
    }
    final bytes = await file.readAsBytes();

    // txt 走字节偏移，避免每次翻章都把整本几 MB 的文本解析一遍。
    if (_isTxt(book, bytes)) {
      final raw = decodeRange(
        bytes,
        chapter.start ?? 0,
        chapter.end ?? bytes.length,
        book.charset,
      );
      final cleaned = TxtParser.cleanTxtChapterBody(raw, chapter.title);
      return (
        _replacer.content(_toHtml(cleaned), _targetOf(book)),
        const <String>[],
        null,
      );
    }

    final parsed = await BookParser.parse(
      bytes,
      fileName: p.basename(book.bookUrl),
      charset: book.charset,
    );
    if (parsed.format == BookFormat.comic) {
      throw const LegadoException(
        ErrorCode.notImplemented,
        '本地漫画请用漫画阅读器（Reader.GetLocalPage 逐页取图）',
      );
    }
    if (parsed.format == BookFormat.pdf) {
      // PDF 的页面由 UI 用平台 PdfRenderer 逐页渲染（见 PdfReaderPage），
      // 这里不返回图片直链——内核没有渲染能力，返回占位提示好过一页空白。
      final pageCount = int.tryParse(parsed.metadata['pageCount'] ?? '') ?? 1;
      return (
        '<p>PDF 文档（共 $pageCount 页），请在 PDF 阅读器中打开。</p>',
        const <String>[],
        null,
      );
    }
    final target = parsed.chapters.length > chapter.index
        ? parsed.chapters[chapter.index]
        : (parsed.chapters.isEmpty ? null : parsed.chapters.last);
    final text = target?.readContent() ?? '';
    return (
      _replacer.content(_toHtml(text), _targetOf(book)),
      const <String>[],
      null,
    );
  }

  // ---- 自动缓存 --------------------------------------------------------
  //
  // 对齐原版：`BookHelp.saveContent` 在读到哪存到哪（每章一个缓存文件），
  // `ReadBook.preDownload` 在当前章 +2..+N、-2..-min(5,N) 的范围里预取。
  // 差别只在存储：原版落 `downloadDir/cache/<book>/<chapter>` 文本文件，
  // 这里落 `chapter_cache` 表（UI 的缓存管理页直接读它）。
  //
  // 原版**没有时间过期**：缓存只在「目录 URL 变了」或用户手动清理时失效。
  // `cache.expireDays` 是本实现的扩展，默认 0（永不过期）。

  /// 预取队列（key 是 bookUrl）；同一本书串行抓，不并发打源。
  final Map<String, List<int>> _prefetchQueue = <String, List<int>>{};
  final Set<String> _prefetchRunning = <String>{};
  /// 上次执行过期扫描时的天数；null 表示本次进程还没扫过。
  /// 记住值而不是只记「扫过」：用户在设置里把 0 改成 7 后应当立即生效，
  /// 一次性布尔会永久跳过，过期清理形同虚设。
  int? _purgedDays;
  bool _closed = false;

  /// 停掉后台预取（模块 close 时调）。已经排队的任务直接丢弃。
  Future<void> close() async {
    _closed = true;
    _prefetchQueue.clear();
  }

  /// 命中条件：同序号同 URL 且正文非空。目录改版后章节换地址时，
  /// 旧缓存必须当作未命中，否则读到的是上一版内容。
  CachedChapter? _cacheHit(Book book, BookChapter chapter) {
    if (book.isLocal || chapter.isVolume) return null;
    final cached = _daos.chapterCache.get(book.bookUrl, chapter.index);
    if (cached == null || cached.html.trim().isEmpty) return null;
    if (cached.url.isNotEmpty &&
        chapter.url.isNotEmpty &&
        cached.url != chapter.url) {
      return null;
    }
    return cached;
  }

  List<String> _decodeImages(String json) {
    if (json.trim().isEmpty) return const <String>[];
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) return [for (final item in decoded) '$item'];
    } on FormatException {
      // 坏数据当作没有图片，不能让整章打不开。
    }
    return const <String>[];
  }

  /// 图片目录按 bookId 分；预取 worker 只拿着 Book，这里补一次 rowid 查询。
  int _idOfBook(Book book) => _daos.book.idOf(book.bookUrl) ?? 0;

  /// 把刚读完的一章写进缓存。付费/VIP 章与空正文不写。
  void _autoCacheChapter(
    int bookId,
    Book book,
    BookChapter chapter,
    String html,
    List<String> images,
    String? title, {
    bool force = false,
    bool downloadImages = true,
  }) {
    if (!force && !_autoCache) return;
    if (book.isLocal || chapter.isVolume) return;
    if (chapter.isPay || chapter.isVip) return;
    if (html.trim().isEmpty) return;
    final imageJson = jsonEncode(images);
    _daos.chapterCache.put(
      CachedChapter(
        bookUrl: book.bookUrl,
        index: chapter.index,
        title: (title ?? chapter.title).trim(),
        url: chapter.url,
        html: html,
        images: imageJson,
        size: utf8.encode(html).length + utf8.encode(imageJson).length,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ),
    );
    // 正文先落库再下图片：下载慢/失败不能挡住翻章；原版也是
    // `saveContent()` 先写文本，`saveImage()` 独立按张补。
    if (downloadImages && images.isNotEmpty) {
      unawaited(_downloadAndAccountImages(
        bookId,
        book.bookUrl,
        chapter.index,
        images,
      ));
    }
  }

  /// 后台补图并把实际字节数回填到缓存行的 `size`。
  ///
  /// 之前这里只是 `unawaited(downloadChapter(...))`，下载完的字节没进 size，
  /// 导致「自动缓存写入」与「手动 Cache.Start 写入」统计口径不一致，缓存
  /// 管理页对漫画书的占用严重偏小。回填时重新读行：这一章可能在这期间被
  /// 手动缓存重写过（refresh），不能覆盖人家已经算好的 size。
  Future<void> _downloadAndAccountImages(
    int bookId,
    String bookUrl,
    int index,
    List<String> images,
  ) async {
    final cache = _images;
    if (cache == null) return;
    try {
      final bytes = await cache.downloadChapter(bookId, index, images);
      if (bytes <= 0 || _closed) return;
      final current = _daos.chapterCache.get(bookUrl, index);
      if (current == null) return;
      _daos.chapterCache.put(
        CachedChapter(
          bookUrl: current.bookUrl,
          index: current.index,
          title: current.title,
          url: current.url,
          html: current.html,
          images: current.images,
          size: current.size + bytes,
          createdAt: current.createdAt,
        ),
      );
    } on Object {
      // 图片字节只影响统计；下载失败不改变正文缓存。
    }
  }

  /// 按 `cache.expireDays` 清理过期缓存；同一天数在一个进程里只扫一次。
  void _purgeExpiredCacheIfNeeded() {
    final days = _cacheExpireDays;
    if (days == _purgedDays) return;
    _purgedDays = days;
    if (days <= 0) return;
    try {
      // 先删磁盘图片再删数据库行：反过来会留下无主目录，且下次缓存同章时
      // 旧图会「复活」。原版没有 TTL，这是本实现的扩展，语义要和手动清理一致。
      final expired = _daos.chapterCache.expired(days);
      for (final item in expired) {
        final bookId = _daos.book.idOf(item.bookUrl);
        if (bookId == null) continue;
        _images?.removeChapterDir(bookId, item.index);
      }
      _daos.chapterCache.purgeExpired(days);
    } on Object {
      // 清理失败不该影响阅读；下次进程启动再试。
    }
  }

  /// 排入预取任务（原版 `ReadBook.preDownload` 的章节范围）。
  void _schedulePrefetch(Book book, int currentIndex, int total) {
    if (!_autoCache) return;
    if (book.isLocal) return;
    final num = _preDownloadNum;
    if (num < 1 || total <= 0) return;

    final queue = _prefetchQueue.putIfAbsent(book.bookUrl, () => <int>[]);
    void add(int index) {
      if (index < 0 || index >= total || index == currentIndex) return;
      if (!queue.contains(index)) queue.add(index);
    }

    // 往后：跳过后一章（很可能是正在预加载的下一章），对齐原版 `+2..+N`。
    final end = currentIndex + num < total - 1 ? currentIndex + num : total - 1;
    for (var i = currentIndex + 2; i <= end; i++) {
      add(i);
    }
    // 往前回补，最多 5 章（原版 `-min(5, preDownloadNum)`）。
    final back = num < 5 ? num : 5;
    for (var i = currentIndex - 2; i >= currentIndex - back; i--) {
      add(i);
    }

    if (_prefetchRunning.contains(book.bookUrl)) return;
    unawaited(_runPrefetch(book));
  }

  /// 预取 worker：单书串行，命中缓存就跳过；单章失败不重试（下次阅读会再排）。
  Future<void> _runPrefetch(Book book) async {
    final key = book.bookUrl;
    _prefetchRunning.add(key);
    try {
      // 开关只在这里读一次：预取过程中改设置不需要立刻生效，少查一次库。
      while (!_closed) {
        final queue = _prefetchQueue[key];
        if (queue == null || queue.isEmpty) break;
        final index = queue.removeAt(0);
        try {
          final chapter = _daos.chapter.getChapter(key, index);
          if (chapter == null || chapter.isVolume) continue;
          if (_cacheHit(book, chapter) != null) continue;
          final (html, images, title) = await _contentOf(book, chapter);
          _autoCacheChapter(_idOfBook(book), book, chapter, html, images, title);
        } on Object {
          // 单章失败继续下一章；原版也是重试 3 次后放弃。
          // 库已关闭/模块已卸载时这里也会抛，直接退出循环。
          if (_closed) break;
        }
      }
    } finally {
      _prefetchRunning.remove(key);
      _prefetchQueue.remove(key);
    }
  }

  /// 本地书是不是 txt：优先用入库时的 kind/charset，再回落到扩展名。
  bool _isTxt(Book book, List<int> head) {
    final kind = (book.kind ?? '').toLowerCase();
    if (kind == 'txt' || kind == 'text') return true;
    if (kind == 'epub' || kind == 'umd' || kind == 'pdf') return false;
    final ext = p.extension(book.bookUrl).replaceFirst('.', '').toLowerCase();
    if (ext == 'txt' || ext == 'epub' || ext == 'umd' || ext == 'pdf') {
      return ext == 'txt';
    }
    return detect(head, p.basename(book.bookUrl)) == BookFormat.txt;
  }

  /// 纯文本 → UI 能消费的最简 HTML。
  ///
  /// UI 的 `HtmlText.toParagraphs` 把 `</p>` 当段落边界，所以这里一行一个
  /// `<p>`；转义交给 dart:convert，不要自己 replace `&`/`<`。
  String _toHtml(String text) {
    final buffer = StringBuffer();
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trimRight();
      if (trimmed.isEmpty) continue;
      buffer.write('<p>${_escape.convert(trimmed)}</p>');
    }
    return buffer.toString();
  }

  String _normalizeTitle(String title) =>
      title.replaceAll('\u00A0', ' ').trim();
}
