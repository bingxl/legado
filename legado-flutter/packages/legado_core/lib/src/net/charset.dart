/// 编码探测与解码。
///
/// 对齐原版 `OkHttpUtils.kt` 的 `ResponseBody.text(encode)` 行为：
/// 显式 charset > 响应头 Content-Type > 内容嗅探（BOM / meta / 启发式）> 兜底。
///
/// 与 JVM 的差异：Dart 没有 juniversalchardet 的对等物，`EncodingDetect` 那套
/// 频率统计做不出来（也不值得为它引一个几 MB 的表）。书源站点的实际分布是
/// 「UTF-8 绝大多数 + 老站 GBK」，所以用「UTF-8 合法性检查 → 否则 GBK」这条
/// 极窄的启发式就够，误判面比统计法还小。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;

/// meta 嗅探的扫描上限。
///
/// 有的站点会塞几 KB 的注释、统计脚本，把 `<meta charset>` 顶到 1 KB 之后；
/// 原版 legado 扫 4096 字节，这里保持一致。
const int kMetaScanLimit = 4096;

/// 启发式的取样上限。
const int kHeuristicSampleSize = 1024;

const Set<String> _gbkAliases = {
  'gbk',
  'gb2312',
  'gb18030',
  'gb_2312-80',
  'x-gbk',
  'cp936',
  'windows-936',
  'euc-cn',
};

const Set<String> _utf8Aliases = {'utf-8', 'utf8', 'unicode-1-1-utf-8'};

const Set<String> _latin1Aliases = {
  'iso-8859-1',
  'iso8859-1',
  'latin1',
  'latin-1',
  'l1',
  'windows-1252',
  'cp1252',
};

final RegExp _charsetParamRe = RegExp(
  r'''charset\s*=\s*["']?\s*([a-zA-Z0-9_\-:.]+)''',
  caseSensitive: false,
);

final RegExp _metaCharsetRe = RegExp(
  r'''<meta[^>]+charset\s*=\s*["']?\s*([a-zA-Z0-9_\-:.]+)''',
  caseSensitive: false,
);

final RegExp _xmlEncodingRe = RegExp(
  r'''<\?xml[^>]+encoding\s*=\s*["']\s*([a-zA-Z0-9_\-:.]+)''',
  caseSensitive: false,
);

/// 归一化编码名。
///
/// 返回 `utf-8` / `gbk` / `utf-16le` / `utf-16be` / `latin1` 之一，
/// 无法识别时返回小写原名（[decode] 会再兜底）。
String normalizeCharset(String? name) {
  if (name == null) return '';
  var n = name.trim().toLowerCase();
  if (n.isEmpty) return '';
  // 去掉 `charset=` 前缀与引号，方便直接吃整段 Content-Type。
  if (n.startsWith('charset=')) {
    n = n.substring(8).trim();
  }
  n = n.replaceAll('"', '').replaceAll("'", '').trim();
  if (n.isEmpty) return '';
  if (_utf8Aliases.contains(n)) return 'utf-8';
  if (_gbkAliases.contains(n)) return 'gbk';
  if (_latin1Aliases.contains(n)) return 'latin1';
  switch (n) {
    case 'utf-16':
    case 'utf-16le':
    case 'utf16le':
    case 'ucs-2':
      return 'utf-16le';
    case 'utf-16be':
    case 'utf16be':
      return 'utf-16be';
  }
  return n;
}

/// 从 Content-Type 取 charset。
///
/// 例：`text/html; charset=GBK` → `gbk`；没有则返回 null。
String? charsetFromContentType(String? contentType) {
  if (contentType == null || contentType.isEmpty) return null;
  final m = _charsetParamRe.firstMatch(contentType);
  if (m == null) return null;
  final cs = normalizeCharset(m.group(1));
  return cs.isEmpty ? null : cs;
}

/// 从 HTML 头部嗅探编码声明。
///
/// 用 latin1 解码再跑正则：meta 声明一定是 ASCII 可表示的，先用 UTF-8 解会在
/// GBK 正文上抛异常（或产生替换字符），反而让正则匹配不到。
String? sniffFromHtml(List<int> bytes, {int limit = kMetaScanLimit}) {
  if (bytes.isEmpty) return null;
  final end = bytes.length < limit ? bytes.length : limit;
  // 只取到 end，但不要切断一个多字节字符——ascii 解码不关心边界。
  final head = String.fromCharCodes(bytes, 0, end);

  final meta = _metaCharsetRe.firstMatch(head);
  if (meta != null) {
    final cs = normalizeCharset(meta.group(1));
    if (cs.isNotEmpty) return cs;
  }
  final xml = _xmlEncodingRe.firstMatch(head);
  if (xml != null) {
    final cs = normalizeCharset(xml.group(1));
    if (cs.isNotEmpty) return cs;
  }
  return null;
}

/// 严格 UTF-8 合法性检查（不合法就说明不是 UTF-8，无需猜测）。
///
/// 只检前 [limit] 字节：GBK 站点 99% 在首屏就有中文，采样足够，
/// 而正文级检查会让每次请求都多扫一遍几十 MB。
bool isValidUtf8(List<int> bytes, {int limit = -1}) {
  final len = limit < 0 || limit > bytes.length ? bytes.length : limit;
  var i = 0;
  while (i < len) {
    final b = bytes[i];
    if (b < 0x80) {
      i++;
      continue;
    }
    int need;
    if (b >= 0xC2 && b <= 0xDF) {
      need = 1;
    } else if (b >= 0xE0 && b <= 0xEF) {
      need = 2;
    } else if (b >= 0xF0 && b <= 0xF4) {
      need = 3;
    } else {
      return false;
    }
    if (i + need >= len) {
      // 采样边界被切断：后续字节未知，按「已扫描部分合法」处理，
      // 避免把截断的 UTF-8 误判成 GBK。
      return true;
    }
    for (var k = 1; k <= need; k++) {
      final c = bytes[i + k];
      if ((c & 0xC0) != 0x80) return false;
    }
    // 排除过长编码与代理区
    if (need == 2) {
      final b1 = bytes[i + 1];
      if (b == 0xE0 && b1 < 0xA0) return false;
      if (b == 0xED && b1 > 0x9F) return false;
    } else if (need == 3) {
      final b1 = bytes[i + 1];
      if (b == 0xF0 && b1 < 0x90) return false;
      if (b == 0xF4 && b1 > 0x8F) return false;
    }
    i += need + 1;
  }
  return true;
}

/// BOM 探测结果。
class BomInfo {
  const BomInfo(this.charset, this.length);

  final String charset;
  final int length;
}

/// 识别 BOM。没有 BOM 返回 null。
BomInfo? detectBom(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return const BomInfo('utf-8', 3);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return const BomInfo('utf-16le', 2);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return const BomInfo('utf-16be', 2);
  }
  return null;
}

/// 解码字节为字符串。
///
/// 优先级：
/// 1. BOM（带内信号，最可靠；响应头写 utf-8 而实际是 UTF-16 的情况真实存在）
/// 2. [declaredCharset]（调用方显式指定，或从 Content-Type 解析出来）
/// 3. HTML `<meta charset>` / `<?xml encoding=?>`
/// 4. 启发式：前 1 KB 是合法 UTF-8 → UTF-8，否则 GBK
/// 5. 兜底 UTF-8（容错模式，绝不抛异常）
String decode(
  List<int> bytes, {
  String? declaredCharset,
  String? contentType,
  int metaLimit = kMetaScanLimit,
}) {
  if (bytes.isEmpty) return '';

  final bom = detectBom(bytes);
  if (bom != null) {
    return _decodeWith(bytes.sublist(bom.length), bom.charset);
  }

  var cs = normalizeCharset(declaredCharset);
  if (cs.isEmpty) cs = charsetFromContentType(contentType) ?? '';
  if (cs.isEmpty) cs = sniffFromHtml(bytes, limit: metaLimit) ?? '';
  if (cs.isEmpty) cs = _guess(bytes);
  return _decodeWith(bytes, cs);
}

String _guess(List<int> bytes) {
  final sample = bytes.length < kHeuristicSampleSize
      ? bytes
      : bytes.sublist(0, kHeuristicSampleSize);
  var hasHighByte = false;
  for (final b in sample) {
    if (b >= 0x80) {
      hasHighByte = true;
      break;
    }
  }
  if (!hasHighByte) return 'utf-8';
  return isValidUtf8(bytes, limit: kHeuristicSampleSize) ? 'utf-8' : 'gbk';
}

String _decodeWith(List<int> bytes, String charset) {
  switch (charset) {
    case 'utf-8':
      return _stripUtf8Bom(utf8.decode(bytes, allowMalformed: true));
    case 'gbk':
      return _decodeGbk(bytes);
    case 'utf-16le':
      return _decodeUtf16(bytes, littleEndian: true);
    case 'utf-16be':
      return _decodeUtf16(bytes, littleEndian: false);
    case 'latin1':
      return String.fromCharCodes(bytes);
  }
  // 未知编码：先按 UTF-8 容错解，再退回 GBK。
  final asUtf8 = utf8.decode(bytes, allowMalformed: true);
  if (!asUtf8.contains('\uFFFD')) return _stripUtf8Bom(asUtf8);
  return _decodeGbk(bytes);
}

String _stripUtf8Bom(String s) =>
    s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF ? s.substring(1) : s;

String _decodeGbk(List<int> bytes) {
  try {
    return gbk_bytes.decoder.convert(bytes);
  } catch (_) {
    // gbk_codec 的表是「常用字子集」，遇到表外字节不会抛错，但防御一下。
    return String.fromCharCodes(bytes);
  }
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final units = <int>[];
  final data = Uint8List.fromList(bytes);
  final view = ByteData.sublistView(data);
  for (var i = 0; i + 1 < data.length; i += 2) {
    units.add(view.getUint16(i, littleEndian ? Endian.little : Endian.big));
  }
  final s = String.fromCharCodes(units);
  return _stripUtf8Bom(s);
}

/// 把字符串编码成指定 charset 的字节，供 GBK 站点的搜索参数使用。
///
/// 只做「常见中文字符」：表外字符退化成 `?`，这样服务端至少不会把整串参数解成垃圾。
List<int> encode(String text, {String? charset}) {
  final cs = normalizeCharset(charset);
  if (cs.isEmpty || cs == 'utf-8') return utf8.encode(text);
  if (cs == 'gbk') {
    final raw = gbk_bytes.encoder.convert(text);
    // gbk_codec 对表外字符会把 codeUnit 原样写进字节流（>0xFF），
    // 那不是合法字节，统一替换成 '?'。
    return [
      for (final b in raw) (b >= 0 && b <= 0xFF) ? b : 0x3F,
    ];
  }
  if (cs == 'latin1') {
    return [for (final cu in text.codeUnits) (cu <= 0xFF ? cu : 0x3F)];
  }
  return utf8.encode(text);
}
