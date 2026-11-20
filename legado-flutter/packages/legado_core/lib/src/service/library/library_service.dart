import 'dart:io';

import '../../domain/domain.dart';
import '../../format/format.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/store.dart';
import '../shelf/shelf_service.dart';

/// 本地书导入结果，对应契约 `ImportResult`。
class LibraryImportResult {
 const LibraryImportResult({
    this.imported = const [],
    this.failed = const [],
  });

  /// 成功导入/更新的书籍简报（BookBrief）。
  final List<Map<String, Object?>> imported;

  /// 失败项：`{path, reason}`。
  final List<Map<String, Object?>> failed;

  Map<String, Object?> toJson() => <String, Object?>{
        'imported': imported,
        'failed': failed,
      };
}

/// 导出结果，对应契约 `ExportResult`。
class LibraryExportResult {
  const LibraryExportResult({
    required this.path,
    required this.format,
    required this.size,
  });

  final String path;
  final String format;
  final int size;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'format': format,
        'size': size,
      };
}

/// 本地书导入 / 导出。
///
/// 导入只做「解析 → 落库」，不碰阅读器：目录走 `chapters` 表，
/// 正文仍从源文件按字节偏移读（[ParsedChapter.start]/[end]），
/// 这样一本几十 MB 的 txt 不会在导入时被整本复制进数据库。
class LibraryService {
  LibraryService({
    required StoreDaos daos,
    required ShelfService shelf,
    required String homeDir,
  })  : _daos = daos,
        _shelf = shelf,
        _homeDir = homeDir;

  final StoreDaos _daos;
  final ShelfService _shelf;
  final String _homeDir;

  /// 导入本地文件。
  ///
  /// 同一路径重复导入是**更新**（同名书只留一条）：Book 以文件路径为
  /// 主键，重导时整表替换 `chapters`，进度保留。
  Future<LibraryImportResult> importLocalFiles(
    List<String> paths,
    int groupID,
  ) async {
    final imported = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    final normalizedGroup = groupID < 0 ? 0 : groupID;

    for (final path in paths) {
      try {
        final brief = await _importOne(path, normalizedGroup);
        imported.add(brief);
      } on LegadoException catch (e) {
        failed.add(<String, Object?>{'path': path, 'reason': e.message});
      } on Object catch (e) {
        failed.add(<String, Object?>{'path': path, 'reason': '$e'});
      }
    }
    return LibraryImportResult(imported: imported, failed: failed);
  }

  Future<Map<String, Object?>> _importOne(String path, int groupID) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw LegadoException(ErrorCode.notFound, '文件不存在: $path');
    }
    final bytes = await file.readAsBytes();
    final parsed = await BookParser.parse(bytes, fileName: pBasename(path));
    if (parsed.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '没有解析出任何目录');
    }

    final existing = _daos.book.getBookByFileName(path);
    final book = existing ?? Book();
    book
      ..bookUrl = path
      ..origin = BookType.localTag
      ..originName = pBasename(path)
      ..name = parsed.title.isNotEmpty ? parsed.title : pBasename(path)
      ..author = parsed.author ?? ''
      ..kind = _formatKind(parsed.format)
      ..customTag = _formatKind(parsed.format)
      ..type = BookType.local | _formatTypeBit(parsed.format) | book.type & BookType.notShelf
      ..group = groupID > 0 ? groupID : book.group
      ..canUpdate = false
      ..totalChapterNum = parsed.chapters.length
      ..lastCheckTime = DateTime.now().millisecondsSinceEpoch;

    final chapters = <BookChapter>[
      for (var i = 0; i < parsed.chapters.length; i++)
        BookChapter(
          url: '$path#$i',
          bookUrl: path,
          index: i,
          title: parsed.chapters[i].title,
          isVolume: parsed.chapters[i].isVolume,
          start: parsed.chapters[i].start,
          end: parsed.chapters[i].end,
          resourceUrl: parsed.chapters[i].href,
          wordCount: parsed.chapters[i].content?.length.toString(),
        ),
    ];

    runInTransaction(_daos.db, () {
      if (existing == null) {
        _daos.book.insert(book);
      } else {
        _daos.book.update(book);
      }
      _daos.chapter.deleteByBookUrl(path);
      // insertAll 自己会开事务，不能嵌在外层事务里。
      for (final chapter in chapters) {
        _daos.chapter.insert(chapter);
      }
    });

    final id = _daos.book.idOf(path)!;
    return _shelf.brief(id, book);
  }

  /// 导出书籍。
  ///
  /// 目前只实现 txt：把源文件按原样复制到 [destPath]（保留编码与段落，
  /// 不做「章节重组」这种会丢字的操作）。其它格式明确 NOT_IMPLEMENTED，
  /// 不静默生成一个空文件骗过调用方。
  Future<LibraryExportResult> exportBook(
    int bookID,
    String format,
    String destPath,
  ) async {
    final id = _daos.book.getById(bookID);
    if (id == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookID');
    }
    final normalizedFormat = format.trim().toLowerCase();
    if (normalizedFormat != 'txt' &&
        normalizedFormat != 'text' &&
        normalizedFormat.isNotEmpty) {
      throw LegadoException(
        ErrorCode.notImplemented,
        '暂不支持导出 $format（当前仅 txt）',
      );
    }
    final source = File(id.bookUrl);
    if (!source.existsSync()) {
      throw LegadoException(ErrorCode.notFound, '源文件不存在: ${id.bookUrl}');
    }

    final target = destPath.trim().isEmpty
        ? '$_homeDir${Platform.pathSeparator}${pBasename(id.bookUrl)}'
        : destPath;
    final targetFile = File(target);
    final parent = targetFile.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    await source.copy(target);
    final size = await targetFile.length();
    return LibraryExportResult(path: target, format: 'txt', size: size);
  }

  String _formatKind(BookFormat format) => switch (format) {
        BookFormat.txt => 'txt',
        BookFormat.epub => 'epub',
        BookFormat.umd => 'umd',
        BookFormat.comic => 'comic',
        BookFormat.pdf => 'pdf',
        BookFormat.unknown => 'unknown',
      };

  int _formatTypeBit(BookFormat format) => switch (format) {
        BookFormat.comic => BookType.image,
        // PDF 与原版 Kotlin 一致按 text 型入库：渲染成图片是阅读器的事，
        // 书架筛选/统计仍把它当「书」而不是「漫画」。
        BookFormat.pdf => BookType.text,
        BookFormat.txt || BookFormat.epub || BookFormat.umd => BookType.text,
        BookFormat.unknown => 0,
      };
}

/// 只取文件名，避免为了一个 basename 在内核里引 `path` 包。
String pBasename(String path) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  return slash < 0 ? path : path.substring(slash + 1);
}
