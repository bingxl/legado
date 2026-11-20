/// 书架导出服务。
///
/// 只做「把已入库的一本书变成离线文件」这件事：逐章走 Reader 域拿正文，
/// 再交给 [buildEpub] 打包。正文/图片抓取链路完全复用 Reader + SourceFetch，
/// 这里不重新解析书源，避免出现「阅读器能看、导出的书缺图」的分叉。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../reader/reader_service.dart';
import '../../store/store.dart';
import 'epub_writer.dart';

/// 对外暴露的格式能力。
///
/// `implemented=false` 的格式保留在列表里，调用 [ExportService.exportBook]
/// 会得到明确的 NOT_IMPLEMENTED，而不是静默返回一个空文件。
class ExportFormat {
  const ExportFormat({
    required this.id,
    required this.name,
    required this.extension,
    required this.implemented,
  });

  final String id;
  final String name;
  final String extension;
  final bool implemented;

  Map<String, Object?> toView() => <String, Object?>{
        'id': id,
        'name': name,
        'extension': extension,
        'implemented': implemented,
      };
}

class ExportService {
  ExportService({
    required StoreDaos daos,
    required ReaderService reader,
    required String homeDir,
    NetClient? net,
  })  : _daos = daos,
        _reader = reader,
        _homeDir = homeDir,
        _net = net ?? NetClient(timeout: const Duration(seconds: 20));

  final StoreDaos _daos;
  final ReaderService _reader;
  final String _homeDir;
  final NetClient _net;

  static const List<ExportFormat> formats = <ExportFormat>[
    ExportFormat(
      id: 'epub',
      name: 'EPUB',
      extension: 'epub',
      implemented: true,
    ),
    ExportFormat(
      id: 'txt',
      name: 'TXT（纯文本）',
      extension: 'txt',
      implemented: false,
    ),
    ExportFormat(
      id: 'mobi',
      name: 'MOBI / AZW3',
      extension: 'mobi',
      implemented: false,
    ),
    ExportFormat(
      id: 'pdf',
      name: 'PDF',
      extension: 'pdf',
      implemented: false,
    ),
  ];

  List<Map<String, Object?>> formatViews() =>
      [for (final format in formats) format.toView()];

  ExportFormat _requireFormat(String raw) {
    final id = raw.trim().toLowerCase();
    if (id.isEmpty) return formats.first; // 默认 EPUB
    for (final format in formats) {
      if (format.id == id) return format;
    }
    throw LegadoException(
      ErrorCode.invalid,
      '不支持的导出格式: $raw（可选: ${formats.map((f) => f.id).join(', ')}）',
    );
  }

  /// 导出一本书。
  ///
  /// [outputDir] 是目标目录（可为空，默认 `<home>/exports`），文件名由书名生成。
  /// 返回 `path / format / chapters / images / title`。
  Future<Map<String, Object?>> exportBook(
    int bookId,
    String formatRaw,
    String outputDir,
  ) async {
    final format = _requireFormat(formatRaw);
    if (!format.implemented) {
      throw LegadoException(
        ErrorCode.notImplemented,
        '${format.name} 导出接口已预留，当前只实现了 EPUB',
      );
    }

    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }

    final chapters = <EpubChapter>[];
    final chapterRows = _reader.getChapters(bookId);
    for (final row in chapterRows) {
      if (row['isVolume'] == true) continue;
      final index = (row['index'] as num?)?.toInt() ?? -1;
      if (index < 0) continue;
      final title = '${row['title'] ?? ''}';
      try {
        final content = await _reader.getContent(bookId, index);
        chapters.add(
          EpubChapter(
            index: index,
            title: title,
            html: '${content['html'] ?? ''}',
          ),
        );
      } on LegadoException {
        // 单章抓取失败不能毁掉整本导出：记一条说明，继续下一章。
        chapters.add(
          EpubChapter(
            index: index,
            title: title,
            html: '<p>本章导出失败（原站抓取异常）。</p>',
          ),
        );
      }
    }
    if (chapters.isEmpty && chapterRows.isNotEmpty) {
      throw const LegadoException(
        ErrorCode.netTimeout,
        '所有章节都导出失败，请检查网络或书源后重试',
      );
    }

    final coverUrl = book.displayCover.trim();
    List<int>? coverBytes;
    var coverExtension = 'jpg';
    if (coverUrl.isNotEmpty) {
      final image = await _fetchImage(coverUrl);
      if (image != null) {
        coverBytes = image.bytes;
        coverExtension = image.extension;
      }
    }

    final bytes = await buildEpub(
      EpubBook(
        title: book.name.isEmpty ? '未命名书籍' : book.name,
        author: book.author,
        intro: book.displayIntro,
        identifierSeed: book.bookUrl.isNotEmpty ? book.bookUrl : 'book:$bookId',
        coverUrl: coverUrl,
        coverBytes: coverBytes,
        coverExtension: coverExtension,
        chapters: chapters,
      ),
      imageFetcher: _fetchImage,
    );

    final dir = Directory(
      outputDir.trim().isEmpty
          ? p.join(_homeDir, 'exports')
          : outputDir.trim(),
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final fileName = _safeFileName(book.name.isEmpty ? '未命名书籍' : book.name);
    final path = p.join(dir.path, '$fileName.${format.extension}');
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);

    return <String, Object?>{
      'path': path,
      'format': format.id,
      'title': book.name,
      'chapters': chapters.length,
      'bytes': bytes.length,
    };
  }

  Future<EpubImage?> _fetchImage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    try {
      // 防盗链图（超星等）要带同源 Referer，规则与 UI 的 imageHeaders 一致。
      final origin = '${uri.scheme}://${uri.host}/';
      final response = await _net.get(
        uri,
        headers: <String, String>{'Referer': origin},
        timeout: const Duration(seconds: 15),
      );
      if (!response.isSuccess || response.bodyBytes.isEmpty) return null;
      var extension = p.extension(uri.path).replaceFirst('.', '').toLowerCase();
      if (extension.isEmpty) {
        final types = response.headers['content-type'];
        final contentType = (types != null && types.isNotEmpty) ? types.first : '';
        extension = contentType.contains('png')
            ? 'png'
            : contentType.contains('gif')
                ? 'gif'
                : contentType.contains('webp')
                    ? 'webp'
                    : 'jpg';
      }
      return EpubImage(response.bodyBytes, extension);
    } on Object {
      // 图片是可有可无的：失败时正文保留原始外链，整本导出继续。
      return null;
    }
  }
}

String _safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  if (cleaned.isEmpty) return 'book';
  // 文件名过长在 Windows 会撞 MAX_PATH，给后缀留出余量。
  return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
}
