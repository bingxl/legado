import 'dart:convert';

import 'parsed_book.dart';
import 'text_codec.dart';

/// 格式识别。
///
/// 顺序是硬要求：**扩展名 → 魔数 → 内容启发式**。
///
/// 只靠扩展名不行（用户会把 epub 改名成 .zip，或根本没有扩展名的下载文件）；
/// 只靠魔数也不行（纯文本没有任何魔数）。所以先信扩展名（用户意图最强），
/// 再用魔数纠正明显不对的扩展名，最后才做文本兜底。
BookFormat detect(List<int> head, String? fileName) {
  final byExtension = _fromExtension(fileName);
  if (byExtension != null) {
    // 扩展名说是 zip 派生格式时，仍要看内容才能分清 epub / 漫画。
    if (byExtension == BookFormat.comic) {
      return _fromZipContent(head) ?? BookFormat.comic;
    }
    if (byExtension == BookFormat.txt) {
      // .txt 里塞了 epub 的情况确实存在（下载站乱改名），魔数优先。
      final magic = _fromMagic(head);
      if (magic == BookFormat.epub ||
          magic == BookFormat.pdf ||
          magic == BookFormat.umd) {
        return magic!;
      }
      return BookFormat.txt;
    }
    return byExtension;
  }

  final magic = _fromMagic(head);
  if (magic != null) return magic;

  // 兜底：能按 UTF-8 / GBK 解出像样的文本就按 txt 处理。
  if (_looksLikeText(head)) return BookFormat.txt;
  return BookFormat.unknown;
}

BookFormat? _fromExtension(String? fileName) {
  if (fileName == null) return null;
  final base = fileName.split(RegExp(r'[\\/]')).last.toLowerCase();
  final dot = base.lastIndexOf('.');
  if (dot < 0) return null;
  switch (base.substring(dot + 1)) {
    case 'txt':
      return BookFormat.txt;
    case 'epub':
      return BookFormat.epub;
    case 'umd':
      return BookFormat.umd;
    case 'pdf':
      return BookFormat.pdf;
    case 'zip':
    case 'cbz':
      // 要用内容再判一次 epub / 漫画
      return BookFormat.comic;
    default:
      return null;
  }
}

BookFormat? _fromMagic(List<int> head) {
  if (head.length < 4) return null;

  // UMD：0xDE9A9B89（小端存储为 89 9B 9A DE）
  if (head[0] == 0x89 && head[1] == 0x9B && head[2] == 0x9A && head[3] == 0xDE) {
    return BookFormat.umd;
  }
  // PDF
  if (head[0] == 0x25 && head[1] == 0x50 && head[2] == 0x44 && head[3] == 0x46) {
    return BookFormat.pdf;
  }
  // ZIP（PK\x03\x04）
  if (head[0] == 0x50 && head[1] == 0x4B &&
      (head[2] == 0x03 || head[2] == 0x05 || head[2] == 0x07) &&
      (head[3] == 0x04 || head[3] == 0x06 || head[3] == 0x08)) {
    return _fromZipContent(head) ?? BookFormat.comic;
  }
  return null;
}

/// zip 里是 epub 还是漫画。
///
/// 不解析 zip 中央目录（head 可能只有 1KB，也不保证读完），
/// 直接找特征字节：EPUB 规范要求第一个条目是未压缩的 `mimetype`，
/// 所以 `application/epub+zip` 一定落在文件开头附近。
BookFormat? _fromZipContent(List<int> head) {
  if (_containsAscii(head, 'application/epub+zip')) return BookFormat.epub;
  if (_containsAscii(head, 'META-INF/container.xml')) return BookFormat.epub;
  return null;
}

bool _containsAscii(List<int> haystack, String needle) {
  final pattern = ascii.encode(needle);
  if (pattern.length > haystack.length) return false;
  final limit = haystack.length - pattern.length;
  for (var i = 0; i <= limit; i++) {
    var hit = true;
    for (var k = 0; k < pattern.length; k++) {
      if (haystack[i + k] != pattern[k]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// 这段字节像不像文本。
///
/// 判据：没有 NUL（二进制几乎必有），且按探测出的编码解出来替换字符不多。
bool _looksLikeText(List<int> head) {
  if (head.isEmpty) return false;
  final limit = head.length < 4096 ? head.length : 4096;
  for (var i = 0; i < limit; i++) {
    if (head[i] == 0x00) {
      // UTF-16 文本天然带 NUL，交给 decodeText 判断。
      final charset = detectCharset(head);
      if (charset == CharsetName.utf16le || charset == CharsetName.utf16be) {
        return true;
      }
      return false;
    }
  }
  final text = decodeText(head);
  if (text.isEmpty) return false;
  final replacement = '\uFFFD'.codeUnitAt(0);
  var bad = 0;
  var controls = 0;
  for (final unit in text.codeUnits) {
    if (unit == replacement) {
      bad++;
    } else if (unit < 0x20 &&
        unit != 0x09 &&
        unit != 0x0A &&
        unit != 0x0D) {
      // 控制字符在文本里几乎不存在；整片 0x01 这种就是二进制。
      controls++;
    }
  }
  if (controls > text.length * 0.01) return false;
  return bad <= text.length * 0.01;
}
