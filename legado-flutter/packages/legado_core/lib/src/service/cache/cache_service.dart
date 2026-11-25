import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../store/store.dart';
import '../../net/net.dart' show CancelToken;
import '../reader/reader_service.dart';
import '../shelf/shelf_service.dart';
import 'cache_job.dart';
import 'image_cache_service.dart';

/// 章节缓存服务。
///
/// 任务状态放在内存里：进程重启后后台任务本来就不可能继续，
/// 而已缓存的章节在 `chapter_cache` 表里，列表/统计不受影响。
/// 单书互斥：同一本书只保留一个 job，重复 Start 返回进行中的那个。
class CacheService {
  CacheService({
    required StoreDaos daos,
    required ReaderService reader,
    required ShelfService shelf,
    required String homeDir,
    ImageCacheService? images,
  })  : _daos = daos,
        _reader = reader,
        _shelf = shelf,
        _homeDir = homeDir,
        _images = images ?? (homeDir.isEmpty ? null : ImageCacheService(homeDir: homeDir));

  final StoreDaos _daos;
  final ReaderService _reader;
  final ShelfService _shelf;
  final String _homeDir;

  /// 与 ReaderService 共享同一个实例（下载闸门 + cookie 池）。
  final ImageCacheService? _images;

  final Map<int, CacheJob> _jobs = <int, CacheJob>{};
  final Set<int> _cancelled = <int>{};
  final Map<int, CancelToken> _imageCancel = <int, CancelToken>{};
  bool _closed = false;

  /// 启动缓存任务，立即回执，后台异步执行。
  CacheJob start(int bookId, String scope, List<int> indexes) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    if (!CacheScope.values.contains(scope)) {
      throw LegadoException(
        ErrorCode.invalid,
        '未知的缓存范围: $scope（可选 ${CacheScope.values.join('/')}）',
      );
    }
    if (_closed) {
      throw const LegadoException(ErrorCode.internal, '缓存服务已关闭');
    }
    final book = _requireBook(bookId);
    final chapters = _daos.chapter.getChapterList(book.bookUrl);
    if (chapters.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '这本书还没有目录');
    }

    final running = _jobs[bookId];
    if (running != null && running.isRunning) return running;

    final targets = _pickTargets(book, chapters, scope, indexes);
    if (targets.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '没有需要缓存的章节');
    }

    final job = CacheJob(
      bookId: bookId,
      bookName: book.name,
      scope: scope,
      total: targets.length,
      startedAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    _jobs[bookId] = job;
    _cancelled.remove(bookId);
    // 故意不 await：契约要求 Start 立即返回，进度靠 Jobs/事件观察。
    unawaited(_run(book, chapters, job, targets));
    return job;
  }

  Future<void> _run(
    Book book,
    List<BookChapter> chapters,
    CacheJob job,
    List<int> targets,
  ) async {
    final byIndex = {for (final chapter in chapters) chapter.index: chapter};
    var succeeded = 0;
    for (final index in targets) {
      if (_closed || _cancelled.contains(job.bookId)) break;
      final chapter = byIndex[index];
      if (chapter == null) continue;
      job.message = chapter.title;
      try {
        // refresh：手动缓存要拿「当前」正文，不能被上一次自动缓存的旧内容骗过去
        // （站点改错字/换图后，用户点「重新缓存」就是想刷新）。
        // downloadImages=false：图片由本任务自己 await 并计入进度，避免两边重复下。
        final content = await _reader.getContent(
          job.bookId,
          index,
          refresh: true,
          downloadImages: false,
        );
        final html = '${content['html'] ?? ''}';
        // 与阅读器自动缓存同一套守卫：付费/VIP 章书源本就不给正文，
        // 空正文也不写。否则付费占位文本会被当成有效缓存写进去，
        // CacheScope.missing 随后永远跳过它，用户再也补不到真内容。
        if (chapter.isPay || chapter.isVip || html.trim().isEmpty) {
          succeeded++;
          job.done++;
          continue;
        }
        final rawImages = content['images'];
        final imageUrls = rawImages is List
            ? [for (final url in rawImages) '$url']
            : <String>[];
        final imageJson = jsonEncode(imageUrls);
        var size = utf8.encode(html).length + utf8.encode(imageJson).length;

        // 原版 CacheBook 缓存图片章时会把每张图下载到磁盘（正文缓存不等于
        // 图片缓存），否则断网只能看到一堆失效的地址。单张失败不影响整章，
        // 与原版 BookHelp.saveImage 吞掉单图异常的行为一致。
        if (!_cancelled.contains(job.bookId)) {
          final token =
              _imageCancel.putIfAbsent(job.bookId, () => CancelToken());
          try {
            size += await _images?.downloadChapter(
                  job.bookId,
                  index,
                  imageUrls,
                  cancel: token,
                ) ??
                0;
          } finally {
            _imageCancel.remove(job.bookId);
          }
        }

        _daos.chapterCache.put(CachedChapter(
          bookUrl: book.bookUrl,
          index: index,
          title: '${content['title'] ?? chapter.title}',
          url: chapter.url,
          html: html,
          images: imageJson,
          size: size,
          createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ));
        succeeded++;
        job.done++;
      } on Object catch (e) {
        job.failed++;
        job.message = '$e';
      }
    }

    if (_cancelled.contains(job.bookId)) {
      job.state = CacheState.canceled;
      job.message = '已取消';
    } else if (succeeded == 0 && job.failed > 0) {
      job.state = CacheState.failed;
    } else {
      job.state = CacheState.done;
      job.message = '';
    }
    job.finishedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  List<int> _pickTargets(
    Book book,
    List<BookChapter> chapters,
    String scope,
    List<int> indexes,
  ) {
    // 分卷标题不是正文，缓存它只会得到空 html。
    final readable = <int, BookChapter>{};
    final ordered = <int>[];
    for (final chapter in chapters) {
      if (chapter.isVolume) continue;
      readable[chapter.index] = chapter;
      ordered.add(chapter.index);
    }
    ordered.sort();

    switch (scope) {
      case CacheScope.all:
        return ordered;
      case CacheScope.remaining:
        final start = book.durChapterIndex < 0 ? 0 : book.durChapterIndex;
        final rest = [for (final index in ordered) if (index >= start) index];
        // 进度已到末尾时退化为整本，比「没有需要缓存的章节」有用。
        return rest.isEmpty ? ordered : rest;
      case CacheScope.missing:
        final fresh = <int, String>{
          for (final chapter in chapters) chapter.index: chapter.url,
        };
        final cachedUrls = <int, String>{
          for (final item in _daos.chapterCache.ofBook(book.bookUrl))
            item.index: item.url,
        };
        final freshUrls = <int, String>{
          for (final entry in fresh.entries)
            if (cachedUrls[entry.key] == entry.value) entry.key: entry.value,
        };
        return [
          for (final index in ordered)
            if (!freshUrls.containsKey(index)) index,
        ];
      case CacheScope.chapters:
        final seen = <int>{};
        return [
          for (final index in indexes)
            if (readable.containsKey(index) && seen.add(index)) index,
        ];
      default:
        return const [];
    }
  }

  /// 取消任务（幂等）：没有任务也返回成功。
  void cancel(int bookId) {
    _cancelled.add(bookId);
    // 正在下的图片也要停：一章几十 MB 时不取消会继续跑完整章。
    _imageCancel.remove(bookId)?.cancel();
    final job = _jobs[bookId];
    if (job != null && job.isRunning) {
      job.state = CacheState.canceled;
      job.message = '已取消';
      job.finishedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
  }

  List<Map<String, Object?>> jobs() {
    final all = _jobs.values.toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return [for (final job in all) job.toJson()];
  }

  Map<String, Object?> stats() {
    final stats = _daos.chapterCache.bookStats();
    var chapters = 0;
    var size = 0;
    for (final stat in stats) {
      chapters += stat.chapters;
      size += stat.size;
    }
    final running = _jobs.values.where((job) => job.isRunning).length;
    return <String, Object?>{
      'books': stats.length,
      'chapters': chapters,
      'size': size,
      'running': running,
    };
  }

  /// 有缓存的书；按最近缓存时间倒序，试读书也列出。
  List<Map<String, Object?>> books() {
    final idByUrl = <String, int>{};
    for (final book in _daos.book.all) {
      final id = _daos.book.idOf(book.bookUrl);
      if (id != null) idByUrl[book.bookUrl] = id;
    }
    final out = <Map<String, Object?>>[];
    for (final stat in _daos.chapterCache.bookStats()) {
      final id = idByUrl[stat.bookUrl];
      if (id == null) continue;
      final book = _requireBook(id);
      final brief = _shelf.brief(id, book);
      final freshUrls = <int, String>{
        for (final chapter in _daos.chapter.getChapterList(book.bookUrl))
          chapter.index: chapter.url,
      };
      out.add(<String, Object?>{
        'bookId': id,
        'name': brief['name'],
        'author': brief['author'],
        'cover': brief['cover'],
        'kind': brief['kind'],
        'format': brief['format'],
        'formatLabel': brief['formatLabel'],
        'totalChapters': brief['totalChapters'],
        'cachedChapters': _daos.chapterCache.freshCount(book.bookUrl, freshUrls),
        'size': stat.size,
        'updatedAt': isoStamp(stat.updatedAt),
        'job': _jobs[id]?.toJson(),
      });
    }
    return out;
  }

  List<Map<String, Object?>> chapters(int bookId) {
    final book = _requireBook(bookId);
    return [
      for (final cached in _daos.chapterCache.ofBook(book.bookUrl))
        <String, Object?>{
          'index': cached.index,
          'title': cached.title,
          'size': cached.size,
          'updatedAt': isoStamp(cached.createdAt),
        },
    ];
  }

  Map<String, Object?> status(int bookId) {
    final book = _requireBook(bookId);
    final freshUrls = <int, String>{
      for (final chapter in _daos.chapter.getChapterList(book.bookUrl))
        chapter.index: chapter.url,
    };
    var size = 0;
    for (final cached in _daos.chapterCache.ofBook(book.bookUrl)) {
      size += cached.size;
    }
    return <String, Object?>{
      'bookId': bookId,
      'cachedChapters': _daos.chapterCache.freshCount(book.bookUrl, freshUrls),
      'totalChapters': book.totalChapterNum > 0
          ? book.totalChapterNum
          : _daos.chapter.getChapterCount(book.bookUrl),
      'size': size,
      'job': _jobs[bookId]?.toJson(),
    };
  }

  /// 删除指定章节缓存；`indexes` 为空时什么也不做（UI 已短路）。
  void delete(int bookId, List<int> indexes) {
    if (indexes.isEmpty) return;
    final job = _jobs[bookId];
    if (job != null && job.isRunning) {
      throw const LegadoException(
        ErrorCode.invalid,
        '该书正在缓存中，请先取消再删除',
      );
    }
    final book = _requireBook(bookId);
    _daos.chapterCache.delete(book.bookUrl, indexes);
    for (final index in indexes) {
      _removeChapterDir(bookId, index);
    }
  }

  /// 清空某本书全部缓存（含磁盘图片与本地漫画解压页）并停掉任务。
  void purgeBook(int bookId) {
    if (bookId <= 0) return;
    cancel(bookId);
    final book = _daos.book.getById(bookId);
    if (book != null) _daos.chapterCache.deleteByBook(book.bookUrl);
    _images?.removeBookDir(bookId);
    _removeDir(Directory(p.join(_homeDir, 'cache', 'chapter', '$bookId')));
    // 本地 zip/cbz 阅读时逐页解压到 cache/comic/<bookId>，这条路径没有
    // 到期清理，之前所有清缓存入口都漏了它，看过一本本地漫画就永久残留。
    _removeDir(Directory(p.join(_homeDir, 'cache', 'comic', '$bookId')));
  }

  /// 清空全部缓存与任务。
  void clear() {
    for (final id in _jobs.keys.toList()) {
      cancel(id);
    }
    _daos.chapterCache.clear();
    _removeDir(Directory(p.join(_homeDir, 'cache', 'chapter')));
    _removeDir(Directory(p.join(_homeDir, 'cache', 'comic')));
  }

  Future<void> close() async {
    _closed = true;
    for (final id in _jobs.keys.toList()) {
      cancel(id);
    }
    for (final token in _imageCancel.values) {
      token.cancel();
    }
    _imageCancel.clear();
    _jobs.clear();
    _cancelled.clear();
    // 图片下载器归 ReaderModule 持有的共享实例管，这里不 close。
  }

  Book _requireBook(int bookId) {
    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }
    return book;
  }

  void _removeChapterDir(int bookId, int index) =>
      _removeDir(Directory(p.join(_homeDir, 'cache', 'chapter', '$bookId', '$index')));

  void _removeDir(Directory dir) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // 图片是可再生资源；删不掉不该让主操作失败。
    }
  }

  static String isoStamp(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true)
          .toIso8601String();
}
