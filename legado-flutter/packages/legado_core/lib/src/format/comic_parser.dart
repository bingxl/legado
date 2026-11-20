import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'parsed_book.dart';

/// 漫画（zip/cbz）解析器。
///
/// 只有两件事值得说：
///
/// 1. **按文件名自然排序**。压缩包里的顺序是打包顺序，不是阅读顺序；
///    直接按字符串排序会把 `10.jpg` 排到 `2.jpg` 前面，读者会看到乱序的页。
/// 2. **过滤垃圾条目**。macOS 打包会塞 `__MACOSX/` 和 `.DS_Store`，
///    Windows 会塞 `Thumbs.db`，这些混进书里就是一片"裂图"。
class ComicParser {
  /// zip / cbz 内的图片扩展名。
  static const imageExtensions = {
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'avif',
    'heic',
    'jfif',
  };

  /// rar / 7z 魔数。纯 Dart 没有可靠的解压实现（rar 尤其），遇到就明确拒绝。
  static const _rarMagic = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07];
  static const _sevenZipMagic = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

  ParsedBook parse(Uint8List bytes, {String? fileName}) {
    _rejectUnsupported(bytes, fileName);

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BookParseException('不是有效的 zip/cbz 压缩包', cause: e);
    }

    final entries = archive.files
        .where((f) => f.isFile && _isImageEntry(f.name))
        .toList();
    if (entries.isEmpty) {
      throw BookParseException('压缩包里没有图片');
    }
    entries.sort((a, b) => naturalCompare(a.name, b.name));

    final pages = <ComicPage>[];
    final chapters = <ParsedChapter>[];
    for (var i = 0; i < entries.length; i++) {
      final file = entries[i];
      final name = file.name;
      pages.add(
        ComicPage(
          name: name,
          size: file.size,
          // 惰性读取：一页 2MB，800 页全读进内存就是 1.6GB。
          bytes: () => file.readBytes() ?? Uint8List(0),
        ),
      );
      chapters.add(
        ParsedChapter(
          title: '第 ${i + 1} 页',
          index: i,
          href: name,
        ),
      );
    }

    return ParsedBook(
      title: _titleOf(fileName),
      format: BookFormat.comic,
      chapters: chapters,
      pages: pages,
      metadata: {
        'pageCount': '${pages.length}',
        'fileName': ?fileName,
      },
    );
  }

  void _rejectUnsupported(Uint8List bytes, String? fileName) {
    final lower = (fileName ?? '').toLowerCase();
    if (_startsWith(bytes, _rarMagic) || lower.endsWith('.rar') ||
        lower.endsWith('.cbr')) {
      throw UnsupportedFormatException(
        '暂不支持 rar/cbr 漫画包',
        reason: '纯 Dart 没有可靠的 rar 解码器，请解压后重新打包成 zip/cbz',
      );
    }
    if (_startsWith(bytes, _sevenZipMagic) ||
        lower.endsWith('.7z') ||
        lower.endsWith('.cb7')) {
      throw UnsupportedFormatException(
        '暂不支持 7z 漫画包',
        reason: '请解压后重新打包成 zip/cbz',
      );
    }
  }

  static bool _startsWith(List<int> bytes, List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  static bool _isImageEntry(String name) {
    final path = name.replaceAll('\\', '/');
    if (path.startsWith('__MACOSX/') || path.contains('/__MACOSX/')) {
      return false;
    }
    final base = path.split('/').last;
    if (base.isEmpty || base.startsWith('.')) return false;
    final lower = base.toLowerCase();
    if (lower == 'thumbs.db' || lower == 'desktop.ini') return false;
    final dot = lower.lastIndexOf('.');
    if (dot < 0) return false;
    return imageExtensions.contains(lower.substring(dot + 1));
  }

  static String _titleOf(String? fileName) {
    if (fileName == null || fileName.trim().isEmpty) return '未命名漫画';
    final base = fileName.split(RegExp(r'[\\/]')).last;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }
}

/// 自然排序：数字段按数值比，其余按字符比。
///
/// `1.jpg < 2.jpg < 10.jpg`，而普通字符串排序会给 `1, 10, 2`。
int naturalCompare(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final ca = a.codeUnitAt(i);
    final cb = b.codeUnitAt(j);
    final da = _isDigit(ca);
    final db = _isDigit(cb);
    if (da && db) {
      var si = i;
      var sj = j;
      while (si < a.length && _isDigit(a.codeUnitAt(si))) {
        si++;
      }
      while (sj < b.length && _isDigit(b.codeUnitAt(sj))) {
        sj++;
      }
      final na = int.tryParse(a.substring(i, si)) ?? 0;
      final nb = int.tryParse(b.substring(j, sj)) ?? 0;
      if (na != nb) return na.compareTo(nb);
      // 数值相同（如 01 与 1）时，短的那个在前，保持稳定。
      if (si - i != sj - j) return (sj - j).compareTo(si - i);
      i = si;
      j = sj;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  return (a.length - i).compareTo(b.length - j);
}

bool _isDigit(int code) => code >= 0x30 && code <= 0x39;
