/// 本地书籍格式解析的统一入口。
///
/// 内核里只有这一个门面：调用方给「字节 + 文件名」，拿到 [ParsedBook]。
/// 不想暴露各格式解析器的细节（尤其是它们有状态、有缓存），
/// 因为一旦 UI 直接 new 一个 `TxtParser`，编码探测和目录规则就会各自跑一遍，
/// 「同一本书两种章节」的问题随之而来。
library;

import 'dart:typed_data';

import 'comic_parser.dart';
import 'detect.dart';
import 'epub_parser.dart';
import 'parsed_book.dart';
import 'pdf_parser.dart';
import 'txt_parser.dart';
import 'umd_parser.dart';

export 'detect.dart' show detect;
export 'parsed_book.dart';

/// 本地书籍解析门面。
abstract final class BookParser {
  /// 探测格式的前缀字节数。
  ///
  /// 1KB 足够覆盖 epub 的 `mimetype` 条目（规范要求它是第一个且不压缩），
  /// 再多读只是浪费——大文件读 4MB 也会让导入变慢。
  static const headSize = 1024;

  /// 解析一本书。
  ///
  /// [fileName] 用于识别格式与推断书名（TXT 没有内嵌书名）。
  /// [charset] 只对 txt 有意义：为空时自动探测。
  /// [tocRules] 只对 txt 有意义，语法见 `TxtTocRule.parse`。
  ///
  /// 返回 Future 是为了给未来的大文件异步解析留位置（现在全是纯 CPU 同步计算），
  /// 调用方按异步写就不会在后续改造时被迫改签名。
  static Future<ParsedBook> parse(
    Uint8List bytes, {
    String? fileName,
    String? charset,
    List<String>? tocRules,
  }) async {
    if (bytes.isEmpty) {
      throw BookParseException('文件为空');
    }
    final head = bytes.length > headSize
        ? Uint8List.sublistView(bytes, 0, headSize)
        : bytes;

    switch (detect(head, fileName)) {
      case BookFormat.txt:
        return TxtParser(charset: charset, tocRules: tocRules)
            .parse(bytes, fileName: fileName);
      case BookFormat.epub:
        return EpubParser().parse(bytes);
      case BookFormat.umd:
        return UmdParser().parse(bytes);
      case BookFormat.comic:
        return ComicParser().parse(bytes, fileName: fileName);
      case BookFormat.pdf:
        // 内核只抽页数/元数据并切章节；真正的逐页渲染在 UI 层用平台
        // PdfRenderer 完成（见 app 的 PdfReaderPage），不在这里碰字体。
        return PdfParser().parse(bytes, fileName: fileName);
      case BookFormat.unknown:
        throw UnsupportedFormatException(
          '无法识别文件格式',
          reason: '只支持 txt / epub / umd / zip(cbz) 漫画'
              '${fileName == null ? '' : '，当前文件：$fileName'}',
        );
    }
  }
}
