import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/domain.dart';
import '../../format/format.dart';
import '../../format/text_codec.dart';
import '../../format/txt_parser.dart';
import '../../kernel/errors.dart';
import '../../store/database.dart';
import '../../store/store.dart';
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
  })  : _daos = daos,
        _shelf = shelf,
        _sourceFetch = sourceFetch;

  final StoreDaos _daos;
  final ShelfService _shelf;

  /// 网络书正文抓取链路；为 null 时只支持本地书。
  final SourceFetchService? _sourceFetch;

  static const HtmlEscape _escape = HtmlEscape();

  List<Map<String, Object?>> getChapters(int bookId) {
    final book = _requireBook(bookId);
    return [
      for (final chapter in _daos.chapter.getChapterList(book.bookUrl))
        <String, Object?>{
          'index': chapter.index,
          'title': _normalizeTitle(chapter.title),
          'url': chapter.url,
          'isVolume': chapter.isVolume,
          if (book.type & BookType.audio != 0 && chapter.end != null)
            'duration': chapter.end,
        },
    ];
  }

  /// 取正文。
  ///
  /// 本地书按「书 + 章节序号」从源文件读；网络书要经书源抓取，
  /// 那条链路（rules/net/js → Source 域）还没接上，此时明确报 NOT_IMPLEMENTED，
  /// 而不是返回空 html 让 UI 显示一页空白却查不出原因。
  Future<Map<String, Object?>> getContent(int bookId, int index) async {
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
    final (html, images) = await _contentOf(book, chapter);

    return <String, Object?>{
      'bookId': bookId,
      'index': index,
      'title': _normalizeTitle(chapter.title),
      'html': html,
      'images': images,
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

  Future<(String, List<String>)> _contentOf(
    Book book,
    BookChapter chapter,
  ) async {
    if (chapter.isVolume) return ('', const <String>[]);
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
      return fetch.fetchContent(
        source,
        book.bookUrl,
        chapter.url,
        nextChapterUrl: nextChapterUrl,
      );
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
      return (_toHtml(cleaned), const <String>[]);
    }

    final parsed = await BookParser.parse(
      bytes,
      fileName: p.basename(book.bookUrl),
      charset: book.charset,
    );
    if (parsed.format == BookFormat.comic) {
      throw const LegadoException(
        ErrorCode.notImplemented,
        '漫画图片的数据面尚未接入',
      );
    }
    if (parsed.format == BookFormat.pdf) {
      // PDF 的页面由 UI 用平台 PdfRenderer 逐页渲染（见 PdfReaderPage），
      // 这里不返回图片直链——内核没有渲染能力，返回占位提示好过一页空白。
      final pageCount = int.tryParse(parsed.metadata['pageCount'] ?? '') ?? 1;
      return (
        '<p>PDF 文档（共 $pageCount 页），请在 PDF 阅读器中打开。</p>',
        const <String>[],
      );
    }
    final target = parsed.chapters.length > chapter.index
        ? parsed.chapters[chapter.index]
        : (parsed.chapters.isEmpty ? null : parsed.chapters.last);
    final text = target?.readContent() ?? '';
    return (_toHtml(text), const <String>[]);
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
