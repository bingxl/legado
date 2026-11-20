import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/store.dart';

/// 书架服务：11 个 `Shelf.*` 方法的业务实现。
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

  // ----------------------------------------------------------------------
  // 读
  // ----------------------------------------------------------------------

  /// 用户自建分组；内置「全部」（id=1）与负 id 的虚拟分组都不下发。
  List<Map<String, Object?>> listGroups() => [
        for (final group in _daos.bookGroup.selectable)
          if (group.groupId > 1) _groupView(group),
      ];

  /// `groupId=0` 取全部；分组 ID 是位域，用按位与命中。
  List<Map<String, Object?>> listBooks(int groupId) => [
        for (final entry in _daos.book.shelfBooks(groupId))
          brief(entry.$1, entry.$2),
      ];

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

  Map<String, Object?> createGroup(String name) {
    final trimmed = name.trim();
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

  void updateGroup(int id, String name, bool show, int order) {
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
    final dir = Directory(p.join(_chapterCacheRoot, '$id'));
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // 图片缓存是可再生的；删不掉不该让「移出书架」失败。
    }
  }

  Map<String, Object?> _groupView(BookGroup group) => <String, Object?>{
        'id': group.groupId,
        'name': group.groupName,
        'order': group.order,
        'show': group.show,
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
