import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/store.dart';

/// 书架服务：18 个 `Shelf.*` 方法的业务实现。
///
/// 这里刻意不碰网络、不碰书源：书架只负责「已经落库的那本书」的组织与展示。
/// 试读转正（`PutOnShelf`）也只翻一个位域，不重新抓目录/正文——那条路径属于 Source 域。
class ShelfService {
  ShelfService({required StoreDaos daos, required String homeDir})
      : _daos = daos,
        _homeDir = homeDir;

  final StoreDaos _daos;
  final String _homeDir;

  /// 磁盘图片缓存根目录，与旧版 `PurgeBook` 的 `<home>/cache/chapter/<id>` 一致。
  String get _chapterCacheRoot => p.join(_homeDir, 'cache', 'chapter');

  /// 本地 zip/cbz 逐页解压缓存根目录（Reader.GetLocalPage 写入）。
  String get _comicCacheRoot => p.join(_homeDir, 'cache', 'comic');

  // ----------------------------------------------------------------------
  // 读
  // ----------------------------------------------------------------------

  /// 用户自建分组；内置「全部」（id=1）与负 id 的虚拟分组都不下发。
  List<Map<String, Object?>> listGroups() => [
        for (final group in _daos.bookGroup.selectable)
          if (group.groupId > 1) _groupView(group),
      ];

  /// `groupId=0` 取全部；分组 ID 是位域，用按位与命中。
  ///
  /// [sort] 对应原版 `BooksFragment.upRecyclerData` 的 `bookSort`：
  /// 0/-1 = 最近阅读（`durChapterTime`）、1 = 更新目录时间（`latestChapterTime`）、
  /// 2 = 书名、3 = 自定义（保持 `order`）、4 = 综合（两者取大）、5 = 作者。
  ///
  /// 这里原来把 1 写成 `lastCheckTime`（每次检查目录都变，连没更新过的书也会
  /// 往前跳），且缺 5（按作者）；0 与 4 又是同一套排序 —— 4 应该取
  /// `max(latestChapterTime, durChapterTime)`，否则「刚读完的老书」压不过
  /// 「刚更新但没读的」。
  List<Map<String, Object?>> listBooks(int groupId, [int sort = -1]) {
    final entries = _daos.book.shelfBooks(groupId);
    if (sort >= 0 && sort != 3 && entries.length > 1) {
      int byTime(Book a, Book b) => b.durChapterTime.compareTo(a.durChapterTime);
      int byLatest(Book a, Book b) =>
          b.latestChapterTime.compareTo(a.latestChapterTime);
      int byBoth(Book a, Book b) {
        final la = a.latestChapterTime > a.durChapterTime
            ? a.latestChapterTime
            : a.durChapterTime;
        final lb = b.latestChapterTime > b.durChapterTime
            ? b.latestChapterTime
            : b.durChapterTime;
        return lb.compareTo(la);
      }

      // 书名/作者排序：原版用 `Collator.getInstance(Locale.CHINA)`（中文按拼音）。
      // 纯 Dart 没有 ICU，这里退化成「按码点比较」—— 中文顺序与原版不同，
      // 但至少是确定性的、ASCII 部分正确。要完全对齐得引拼音表，代价太大。
      int byText(String a, String b) => a.compareTo(b);
      entries.sort((a, b) => switch (sort) {
            1 => byLatest(a.$2, b.$2),
            4 => byBoth(a.$2, b.$2),
            2 => byText(a.$2.name, b.$2.name),
            5 => byText(a.$2.author, b.$2.author),
            _ => byTime(a.$2, b.$2),
          });
    }
    return [for (final entry in entries) brief(entry.$1, entry.$2)];
  }

  /// 书架 JSON 导出：与原版 `BookshelfViewModel.exportBookshelf` 同格式，
  /// 顶层是数组，每项只有 `name` / `author` / `intro`。
  ///
  /// 刻意不导 bookUrl/group/progress：原版导出的接口就是给「换设备后按书名
  /// 重新搜索加书」用的，带上本机 URL 反而无法在新设备上复用。
  String exportBookshelf(int groupId) {
    final rows = <Map<String, Object?>>[];
    for (final item in listBooks(groupId)) {
      final id = (item['id'] as num?)?.toInt() ?? 0;
      final book = _daos.book.getById(id);
      if (book == null) continue;
      rows.add(<String, Object?>{
        'name': book.name,
        'author': book.author,
        'intro': book.displayIntro,
      });
    }
    return const JsonEncoder.withIndent('  ').convert(rows);
  }

  /// 详情也接受试读书：详情页和阅读器都要能在「加入书架」之前打开。
  Map<String, Object?> getBook(int id) {
    final (bookId, book) = _requireBook(id);
    return <String, Object?>{
      ...brief(bookId, book),
      'intro': book.displayIntro,
      'origin': book.origin,
      'bookUrl': book.bookUrl,
    };
  }

  /// 无记录时返回哨兵 `chapterIndex = -1`（见契约表附录 B 第 3 条）。
  Map<String, Object?> getProgress(int bookId) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final progress = _daos.readingProgress.get(_urlOf(bookId));
    if (progress == null) {
      return <String, Object?>{
        'bookId': bookId,
        'chapterIndex': -1,
        'chapterTitle': '',
        'chapterPos': 0,
        'scrollPercent': 0.0,
      };
    }
    return <String, Object?>{
      'bookId': bookId,
      'chapterIndex': progress.chapterIndex,
      'chapterTitle': progress.chapterTitle,
      'chapterPos': progress.chapterPos,
      'scrollPercent': progress.scrollPercent,
    };
  }

  /// 把已有书的 `notShelf` 位清掉。
  void putOnShelf(int id) {
    final (_, book) = _requireBook(id);
    if (book.type & BookType.notShelf == 0) return;
    book.type &= ~BookType.notShelf;
    book.order = 0;
    _daos.book.update(book);
  }

  // ----------------------------------------------------------------------
  // 写
  // ----------------------------------------------------------------------

  /// 删书：章节、进度、章节缓存与磁盘图片一起清。
  ///
  /// 磁盘先删、数据库后删：中途失败时最多留下一个无主的图片目录，
  /// 反过来则会留下「书已不在库但缓存任务还在写」的幽灵目录。
  void deleteBook(int id) {
    final (_, book) = _requireBook(id);
    _removeChapterCacheDir(id);
    runInTransaction(_daos.db, () {
      _daos.cache.deleteByPrefix('chapter_$id');
      // `chapter_cache` 是「已缓存章节」表，和上面的 `cache` KV（任务状态）
      // 是两张表。只清 KV 会留下一堆无主缓存行：缓存管理页的总量/本数永远
      // 虚高，逐本清理也清不掉（书已不在库，列表里根本看不到它）。
      _daos.chapterCache.deleteByBook(book.bookUrl);
      _daos.chapter.deleteByBookUrl(book.bookUrl);
      _daos.readingProgress.delete(book.bookUrl);
      _daos.book.deleteByUrl(book.bookUrl);
    });
  }

  void moveToGroup(int bookId, int groupId) {
    final (_, book) = _requireBook(bookId);
    if (groupId > 0 && _daos.bookGroup.getById(groupId) == null) {
      throw LegadoException(ErrorCode.notFound, '分组不存在: $groupId');
    }
    book.group = groupId < 0 ? 0 : groupId;
    book.order = 0;
    _daos.book.update(book);
  }

  /// 同一事务写 `books.durChapter*` 与 `reading_progress`。
  ///
  /// 前者供书架列表展示（章级百分比），后者供阅读器精确恢复（章内百分比）。
  void saveProgress(
    int bookId,
    int chapterIndex,
    String chapterTitle,
    int chapterPos,
    double scrollPercent,
  ) {
    if (bookId <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final (_, book) = _requireBook(bookId);
    final now = DateTime.now().millisecondsSinceEpoch;
    runInTransaction(_daos.db, () {
      _daos.book.updateProgress(
        bookId,
        chapterIndex: chapterIndex,
        chapterTitle: chapterTitle,
        chapterPos: chapterPos,
        chapterTime: now,
      );
      _daos.readingProgress.put(
        ReadingProgress(
          bookUrl: book.bookUrl,
          chapterIndex: chapterIndex,
          chapterTitle: chapterTitle,
          chapterPos: chapterPos,
          scrollPercent: scrollPercent.clamp(0.0, 100.0).toDouble(),
          updatedAt: now,
        ),
      );
    });
  }

  /// 编辑书籍信息。
  ///
  /// 字段语义（与 `Book.displayCover` / `displayIntro` 配套）：
  /// - 书名、作者直接写：用户就是想改展示值，原版也这么做；
  /// - 封面、简介写 `custom*`：清空即回落到书源抓来的值，不丢原始数据；
  /// - [groupId] < 0 表示不改分组。
  ///
  /// `books` 上有 `(name, author)` 唯一索引，改名撞库要转成可读错误，
  /// 否则 UI 只会看到一条 SQLite 异常字符串。
  Map<String, Object?> saveBook(
    int id, {
    required String name,
    required String author,
    required String coverUrl,
    required String intro,
    int groupId = -1,
  }) {
    final (bookId, book) = _requireBook(id);
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书名不能为空');
    }
    if (groupId >= 0 && groupId > 1) {
      if (_daos.bookGroup.getById(groupId) == null) {
        throw LegadoException(ErrorCode.notFound, '分组不存在: $groupId');
      }
    }
    book
      ..name = trimmedName
      ..author = author.trim()
      ..customCoverUrl = _blankToNull(coverUrl)
      ..customIntro = _blankToNull(intro);
    if (groupId >= 0) book.group = groupId;
    try {
      _daos.book.update(book);
    } on SqliteException catch (e) {
      // UNIQUE constraint failed: 2067 是 SQLITE_CONSTRAINT_UNIQUE。
      if (e.extendedResultCode == 2067 || '${e.message}'.contains('UNIQUE')) {
        throw const LegadoException(ErrorCode.invalid, '已有同名同作者的书，请换个书名');
      }
      rethrow;
    }
    return getBook(bookId);
  }

  String? _blankToNull(String value) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Map<String, Object?> createGroup(String name) {    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '分组名不能为空');
    }
    if (!_daos.bookGroup.canAddGroup) {
      throw const LegadoException(ErrorCode.invalid, '分组数量已达上限');
    }
    final group = BookGroup(
      groupId: _daos.bookGroup.getUnusedId(),
      groupName: trimmed,
      order: _daos.bookGroup.maxOrder + 1,
      show: true,
    );
    _daos.bookGroup.insert(group);
    return _groupView(group);
  }

  /// 编辑分组。后三个参数可选，兼容旧调用方只传 name/show/order。
  ///
  /// [bookSort] 对应原版 `BookGroup.bookSort`（-1 跟随全局，0..4 是五种排序）；
  /// [enableRefresh] 是原版「更新目录时包含本分组」开关；[cover] 传空串清空封面。
  void updateGroup(
    int id,
    String name,
    bool show,
    int order, {
    String? cover,
    int? bookSort,
    bool? enableRefresh,
  }) {
    if (id <= 1) {
      throw const LegadoException(ErrorCode.invalid, '内置分组不可修改');
    }
    final group = _daos.bookGroup.getById(id);
    if (group == null) {
      throw LegadoException(ErrorCode.notFound, '分组不存在: $id');
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '分组名不能为空');
    }
    group
      ..groupName = trimmed
      ..show = show
      ..order = order;
    if (cover != null) group.cover = cover.trim().isEmpty ? null : cover.trim();
    if (bookSort != null) group.bookSort = bookSort;
    if (enableRefresh != null) group.enableRefresh = enableRefresh;
    _daos.bookGroup.update(group);
  }

  /// 删分组但保留书：位域清掉相应位，组内书回落到未分组。
  void deleteGroup(int id) {
    if (id <= 1) {
      throw const LegadoException(ErrorCode.invalid, '内置分组不可删除');
    }
    final group = _daos.bookGroup.getById(id);
    if (group == null) {
      throw LegadoException(ErrorCode.notFound, '分组不存在: $id');
    }
    runInTransaction(_daos.db, () {
      _daos.bookGroup.delete(group);
      _daos.book.removeGroup(id);
    });
  }

  // ----------------------------------------------------------------------
  // 书架管理（多选批量）
  // ----------------------------------------------------------------------

  /// 批量开关「允许更新目录」，对应原版书架管理的「允许/禁止更新」。
  void setCanUpdate(List<int> bookIds, bool enabled) {
    final books = <Book>[];
    for (final id in bookIds) {
      final book = _daos.book.getById(id);
      if (book != null) books.add(book..canUpdate = enabled);
    }
    runInTransaction(_daos.db, () {
      for (final book in books) {
        _daos.book.update(book);
      }
    });
  }

  /// 批量**移动**到分组：先清掉旧分组位，只保留目标分组。
  /// [groupId] = 0 表示移到「未分组」。
  void moveToGroups(List<int> bookIds, int groupId) {
    if (groupId > 0 && _daos.bookGroup.getById(groupId) == null) {
      throw LegadoException(ErrorCode.notFound, '分组不存在: $groupId');
    }
    final books = <Book>[];
    for (final id in bookIds) {
      final book = _daos.book.getById(id);
      if (book == null) continue;
      book
        ..group = groupId
        ..order = 0;
      books.add(book);
    }
    runInTransaction(_daos.db, () {
      for (final book in books) {
        _daos.book.update(book);
      }
    });
  }

  /// 批量**加入**分组：分组是位域，`|` 上去不影响已有分组。
  /// 原版 `BookshelfManageActivity.upGroup(addToGroupRequestCode)` 就是这个语义。
  void addToGroups(List<int> bookIds, int groupId) {
    if (groupId <= 0) return;
    if (_daos.bookGroup.getById(groupId) == null) {
      throw LegadoException(ErrorCode.notFound, '分组不存在: $groupId');
    }
    final books = <Book>[];
    for (final id in bookIds) {
      final book = _daos.book.getById(id);
      if (book == null) continue;
      book.group |= groupId;
      books.add(book);
    }
    runInTransaction(_daos.db, () {
      for (final book in books) {
        _daos.book.update(book);
      }
    });
  }

  /// 批量删除：逐本走单本删除逻辑，章节/进度/缓存/磁盘图片都清。
  /// 单本失败不阻断其余（缓存目录删不掉本来就不算失败）。
  void deleteBooks(List<int> bookIds) {
    for (final id in bookIds) {
      deleteBook(id);
    }
  }

  // ----------------------------------------------------------------------
  // 内部
  // ----------------------------------------------------------------------

  (int, Book) _requireBook(int id) {
    if (id <= 0) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍 ID');
    }
    final book = _daos.book.getById(id);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $id');
    }
    return (id, book);
  }

  /// `GetProgress` 只需要 URL；找不到书时返回空串，让上层拿到 -1 哨兵而不是崩。
  String _urlOf(int bookId) => _daos.book.getById(bookId)?.bookUrl ?? '';

  void _removeChapterCacheDir(int id) {
    _removeQuietly(Directory(p.join(_chapterCacheRoot, '$id')));
    // 本地漫画解压页也要一起清，否则删书后 cache/comic/<id> 永久残留。
    _removeQuietly(Directory(p.join(_comicCacheRoot, '$id')));
  }

  void _removeQuietly(Directory dir) {
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // 缓存是可再生的；删不掉不该让「移出书架」失败。
    }
  }

  Map<String, Object?> _groupView(BookGroup group) => <String, Object?>{
        'id': group.groupId,
        'name': group.groupName,
        'order': group.order,
        'show': group.show,
        'cover': group.cover ?? '',
        'bookSort': group.bookSort,
        'enableRefresh': group.enableRefresh,
        'builtIn': false,
      };

  /// 对外暴露 BookBrief 拼装：Library 导入后回执也走同一份口径。
  Map<String, Object?> brief(int id, Book book) {
    final total = book.totalChapterNum > 0
        ? book.totalChapterNum
        : _daos.chapter.getChapterCount(book.bookUrl);
    final percent = total > 0
        ? (((book.durChapterIndex + 1) * 100) / total).round().clamp(0, 100)
        : 0;
    final (format, label) = _formatOf(book);
    final lastReadAt = book.durChapterTime > 0
        ? DateTime.fromMillisecondsSinceEpoch(book.durChapterTime).toIso8601String()
        : null;
    return <String, Object?>{
      'id': id,
      'name': book.name,
      'author': book.author,
      'cover': book.displayCover,
      'kind': book.customTag?.isNotEmpty == true ? book.customTag : (book.kind ?? ''),
      'format': format,
      'formatLabel': label,
      'type': book.type,
      'isAudio': book.type & BookType.audio != 0,
      'groupId': book.group,
      'totalChapters': total,
      'lastChapter': book.latestChapterTitle ?? '',
      'durChapterIndex': book.durChapterIndex,
      'durChapterTitle': book.durChapterTitle ?? '',
      'percent': percent,
      'lastReadAt': lastReadAt,
      'updatedAt': lastReadAt ?? '',
      'fileMissing': book.isLocal && !_localFileExists(book.bookUrl),
      'inShelf': book.type & BookType.notShelf == 0,
      'canUpdate': book.canUpdate,
      'origin': book.origin,
    };
  }

  /// 格式优先信类型位域，其次信书源给的 kind，最后才猜文件扩展名。
  (String, String) _formatOf(Book book) {
    final raw = (book.customTag?.isNotEmpty == true ? book.customTag : book.kind) ?? '';
    final kind = raw.toLowerCase();
    if (book.type & BookType.audio != 0 || kind == 'audio') return ('audio', '音频');
    if (book.type & BookType.image != 0 || kind == 'comic') return ('comic', '漫画');
    final ext = p.extension(book.bookUrl).replaceFirst('.', '').toLowerCase();
    final value = switch (kind) {
      'txt' || 'text' => 'txt',
      'epub' => 'epub',
      'umd' => 'umd',
      'pdf' => 'pdf',
      _ => switch (ext) {
          'txt' => 'txt',
          'epub' => 'epub',
          'umd' => 'umd',
          'pdf' => 'pdf',
          _ => 'unknown',
        },
    };
    final label = switch (value) {
      'txt' => '文本',
      'epub' => 'EPUB',
      'umd' => 'UMD',
      'pdf' => 'PDF',
      _ => '未知格式',
    };
    return (value, label);
  }

  bool _localFileExists(String path) =>
      path.isNotEmpty && File(path).existsSync();
}
