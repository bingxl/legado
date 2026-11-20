/// PDF 解析：只做「结构性信息抽取」，不做渲染。
///
/// 渲染是平台能力（Android 自带 `PdfRenderer`），放在 UI 层通过 MethodChannel
/// 完成；内核这一层只回答两件事：
///
/// 1. 这本书有几页（决定章节切分与目录）；
/// 2. 书名/作者等元数据（PDF 里以 PDFDocEncoding / UTF-16BE 写在字典里）。
///
/// 按原版 Kotlin `PdfFile` 的语义，每 [pagesPerChapter] 页切一个「分段」章节，
/// 章节的 `start`/`end` 存**页索引**（不是 txt 的字节偏移）：
/// `start` 含、`end` 不含，章节序号 i 覆盖 `[i*10, min((i+1)*10, pageCount))`。
/// UI 打开 PDF 时用平台拿到的真实页数核对，不一致再走 `Reader.SyncOutline` 回写。
library;

import 'dart:typed_data';

import 'parsed_book.dart';

class PdfParser {
  /// 与原版 `PdfFile.PAGE_SIZE` 一致：每章 10 页。
  static const pagesPerChapter = 10;

  /// 扫描窗口：首尾各 [scanWindow] 字节。
  ///
  /// PDF 的 `/Type /Pages /Count N` 与 Info 字典通常在文件首尾，
  /// 全文件转字符串对几百 MB 的扫描版会把内存打满；首尾各 2MB 足够覆盖。
  static const scanWindow = 2 * 1024 * 1024;

  ParsedBook parse(Uint8List bytes, {String? fileName}) {
    final text = _scanText(bytes);
    final detected = _detectPageCount(text);
    // 页数探测失败时兜底 1 章：UI 打开后会用平台渲染器拿到真实页数并回写目录。
    final pageCount = detected < 1 ? 1 : detected;
    final chapters = <ParsedChapter>[];
    for (var start = 0; start < pageCount; start += pagesPerChapter) {
      final end = (start + pagesPerChapter > pageCount)
          ? pageCount
          : start + pagesPerChapter;
      final index = chapters.length;
      chapters.add(
        ParsedChapter(
          title: '分段_${index + 1}',
          index: index,
          start: start,
          end: end,
          href: 'pdf://page/$start',
          content: '<img src="pdf://page/$start">',
        ),
      );
    }

    final fallbackName = fileName == null
        ? 'PDF 文档'
        : fileName.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '');
    return ParsedBook(
      title: _detectMeta(text, 'Title') ?? fallbackName,
      author: _detectMeta(text, 'Author'),
      format: BookFormat.pdf,
      chapters: chapters,
      metadata: <String, String>{
        'pageCount': '$pageCount',
        'kind': 'pdf',
      },
    );
  }

  /// 首字母为 Latin-1 的字节序列——PDF 的字典关键字 (`/Count`) 都是 ASCII，
  /// 用 Latin-1 一字节一字符映射不会像 UTF-8 解码那样破坏字节边界。
  String _scanText(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    if (bytes.length <= scanWindow * 2) {
      return String.fromCharCodes(bytes);
    }
    final head =
        String.fromCharCodes(Uint8List.sublistView(bytes, 0, scanWindow));
    final tail = String.fromCharCodes(
      Uint8List.sublistView(bytes, bytes.length - scanWindow),
    );
    return '$head\n$tail';
  }

  /// 页数：优先取所有 `/Count N` 的最大值（Pages 树的 count 一定最大），
  /// 否则数 `/Type /Page` 的对象个数，最后兜底 1。
  int _detectPageCount(String text) {
    var best = 0;
    for (final m in RegExp(r'/Count\s+(\d+)').allMatches(text)) {
      final n = int.tryParse(m.group(1) ?? '') ?? 0;
      if (n > best) best = n;
    }
    if (best > 0) return best;
    // 负向断言排除 `/Type /Pages`（书页树根，不是一页）。
    final direct = RegExp(r'/Type\s*/Page(?![sA-Za-z])').allMatches(text).length;
    return direct;
  }

  /// 取 Info 字典里的字符串值：`/Title (...)` 或 `/Title <FEFF...>`。
  String? _detectMeta(String text, String key) {
    final literal = RegExp('/$key\\s*\\(([^)]*)\\)').firstMatch(text);
    if (literal != null) {
      final value = _unescapePdfString(literal.group(1) ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    final hex = RegExp('/$key\\s*<([0-9A-Fa-f]+)>').firstMatch(text);
    if (hex == null) return null;
    final raw = hex.group(1) ?? '';
    if (raw.length < 4) return null;
    // UTF-16BE with BOM: FEFF + 每两字节一个码点。
    if (raw.toUpperCase().startsWith('FEFF')) {
      final units = <int>[];
      for (var i = 4; i + 1 < raw.length; i += 2) {
        final unit = int.tryParse(raw.substring(i, i + 2), radix: 16);
        if (unit != null) units.add(unit);
      }
      if (units.isEmpty) return null;
      final value = String.fromCharCodes(units).trim();
      return value.isEmpty ? null : value;
    }
    // 非 BOM 的 hex 字符串按 Latin-1 解读（PDFDocEncoding 的超集）。
    final units = <int>[];
    for (var i = 0; i + 1 < raw.length; i += 2) {
      final unit = int.tryParse(raw.substring(i, i + 2), radix: 16);
      if (unit != null) units.add(unit);
    }
    final value = String.fromCharCodes(units).trim();
    return value.isEmpty ? null : value;
  }

  String _unescapePdfString(String raw) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      if (raw[i] != r'\' || i + 1 >= raw.length) {
        buffer.write(raw[i]);
        i++;
        continue;
      }
      final next = raw[i + 1];
      switch (next) {
        case 'n':
          buffer.write('\n');
        case 'r':
          buffer.write('\r');
        case 't':
          buffer.write('\t');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case '(':
        case ')':
        case r'\':
          buffer.write(next);
        default:
          // \ddd 八进制：PDF 里用于写不可打印字节。
          final octal = RegExp(r'^[0-7]{1,3}').firstMatch(raw.substring(i + 1));
          if (octal != null) {
            buffer.writeCharCode(
              int.parse(octal.group(0)!, radix: 8),
            );
            i += octal.group(0)!.length;
          } else {
            buffer.write(next);
          }
      }
      i += 2;
    }
    return buffer.toString();
  }
}
