/// 文本编码的最小实现。
///
/// 刻意不依赖 `lib/src/net/charset.dart`：那个模块的编码探测要发 HTTP 请求、
/// 解析 `Content-Type`，属于网络层；而本地书籍只有字节，没有响应头。
/// 两处共用一份代码会把「网络」拖进「文件解析」，反过来也一样。
///
/// 已知短板：没有 Big5 码表（`gbk_codec` 只带 GBK），也没做 ICU 级的统计式探测。
/// 这是有意的取舍——本地 txt 99% 是 UTF-8/GBK，把体积花在少见编码上不划算。
library;

import 'dart:convert';

import 'package:gbk_codec/gbk_codec.dart' as gbk_codec;

/// 支持的编码名（规范化后）。
abstract final class CharsetName {
  static const utf8 = 'utf-8';
  static const gbk = 'gbk';
  static const gb18030 = 'gb18030';
  static const utf16le = 'utf-16le';
  static const utf16be = 'utf-16be';
}

/// 把各种别名收敛成 5 种我们真正实现得了的编码。
String normalizeCharset(String? raw) {
  final name = (raw ?? '').trim().toLowerCase().replaceAll('_', '-');
  if (name.isEmpty) return CharsetName.utf8;
  switch (name) {
    case 'utf-8':
    case 'utf8':
    case 'unicode-1-1-utf-8':
      return CharsetName.utf8;
    case 'gb18030':
      return CharsetName.gb18030;
    case 'gbk':
    case 'gb2312':
    case 'gb-2312':
    case 'gb-2312-80':
    case 'cp936':
    case 'ms936':
    case 'windows-936':
    case 'x-gbk':
      return CharsetName.gbk;
    case 'utf-16':
    case 'utf16':
    case 'ucs-2':
      // 无 BOM 的 "utf-16" 只能猜，交给 decodeText 的启发式
      return 'utf-16';
    case 'utf-16le':
    case 'utf16le':
      return CharsetName.utf16le;
    case 'utf-16be':
    case 'utf16be':
      return CharsetName.utf16be;
    default:
      return CharsetName.utf8;
  }
}

/// UTF-8 BOM。
const _utf8Bom = [0xEF, 0xBB, 0xBF];

/// 文首 BOM 占用的字节数（0 表示没有）。
///
/// 单独导出是因为分章算出的偏移必须跳过 BOM：原版 `TextFile` 里
/// `curOffset` 初始就设成 3，正是这个原因。
int bomLengthOf(List<int> bytes, [String? charset]) =>
    _bomLength(bytes, normalizeCharset(charset));

/// 字节流是否以 UTF-8 BOM 开头。
bool hasUtf8Bom(List<int> bytes) =>
    bytes.length >= 3 &&
    bytes[0] == _utf8Bom[0] &&
    bytes[1] == _utf8Bom[1] &&
    bytes[2] == _utf8Bom[2];

/// 解码字节为字符串。
///
/// BOM 会被消费掉（不进入返回的文本）：否则 BOM 会变成正文第一个字符，
/// 表现为「每本书第一章开头多一个看不见的方块」。
///
/// [charset] 为空时自动探测；探测失败按 UTF-8 处理（宁可乱码也不要打不开）。
String decodeText(List<int> bytes, [String? charset]) {
  final normalized = _resolveCharset(bytes, charset);
  final start = _bomLength(bytes, normalized);
  return _decodeRange(bytes, start, bytes.length, normalized);
}

/// 解码指定字节区间（txt 按偏移取章节正文用）。
///
/// 区间起点正好落在多字节字符中间时，会跳过后半个字符而不是抛异常——
/// 章节偏移是我们自己算的，理论上不会错，但用户手工改过的文件会。
String decodeRange(List<int> bytes, int start, int end, [String? charset]) {
  final normalized = _resolveCharset(bytes, charset);
  final from = start < 0 ? 0 : start;
  final to = end > bytes.length ? bytes.length : end;
  if (from >= to) return '';
  return _decodeRange(bytes, from, to, normalized);
}

String _resolveCharset(List<int> bytes, String? charset) {
  final given = normalizeCharset(charset);
  if (given == 'utf-16') return _guessUtf16(bytes);
  if ((charset ?? '').trim().isEmpty) return detectCharset(bytes);
  return given;
}

/// 声明 "utf-16" 但没说字节序时：BOM 优先，其次看零字节分布。
String _guessUtf16(List<int> bytes) {
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return CharsetName.utf16le;
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return CharsetName.utf16be;
  }
  return _sniffUtf16(bytes) ?? CharsetName.utf16le;
}

String _decodeRange(List<int> bytes, int start, int end, String charset) {
  final slice = start == 0 && end == bytes.length
      ? bytes
      : bytes.sublist(start, end);
  switch (charset) {
    case CharsetName.gbk:
    case CharsetName.gb18030:
      return _decodeGbk(slice);
    case CharsetName.utf16le:
      return _decodeUtf16(slice, littleEndian: true);
    case CharsetName.utf16be:
      return _decodeUtf16(slice, littleEndian: false);
    case CharsetName.utf8:
      return utf8.decode(slice, allowMalformed: true);
    default:
      return utf8.decode(slice, allowMalformed: true);
  }
}

int _bomLength(List<int> bytes, String charset) {
  if (hasUtf8Bom(bytes) &&
      (charset == CharsetName.utf8 || charset == CharsetName.gbk)) {
    // GBK 文件带 UTF-8 BOM 说明探测已判错，这里仍然吃掉 BOM：
    // 留着只会让第一章标题以三个乱码字节开头。
    return 3;
  }
  if (charset == CharsetName.utf16le || charset == CharsetName.utf16be) {
    if (bytes.length >= 2) {
      final b0 = bytes[0];
      final b1 = bytes[1];
      if ((b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF)) return 2;
    }
  }
  return 0;
}

String _decodeGbk(List<int> bytes) {
  // gbk_codec 的 `gbk` 接受的是「合并后的 16 位码」，真正吃原始字节的是
  // `gbk_bytes`。用错了不会报错，只会解出一串控制字符——踩过一次。
  return gbk_codec.gbk_bytes.decode(bytes);
}

String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
  final unit = StringBuffer();
  final len = bytes.length & ~1;
  for (var i = 0; i < len; i += 2) {
    final lo = littleEndian ? bytes[i] : bytes[i + 1];
    final hi = littleEndian ? bytes[i + 1] : bytes[i];
    unit.writeCharCode((hi << 8) | lo);
  }
  return unit.toString();
}

/// BOM 优先，其次 UTF-16 的零字节分布，最后「UTF-8 合法即 UTF-8，否则 GBK」。
///
/// 顺序很关键：GBK 文本几乎不可能通过 UTF-8 合法性校验（双字节高位都是 1），
/// 所以「先试 UTF-8」比任何统计模型都准，且零成本。
String detectCharset(List<int> bytes) {
  if (bytes.isEmpty) return CharsetName.utf8;
  if (bytes.length >= 3 && hasUtf8Bom(bytes)) return CharsetName.utf8;
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return CharsetName.utf16le;
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return CharsetName.utf16be;
  }
  final utf16 = _sniffUtf16(bytes);
  if (utf16 != null) return utf16;
  if (_isValidUtf8(bytes)) return CharsetName.utf8;
  // 没有 Big5 码表，GB18030 是超集，用它兜底覆盖面最大。
  return CharsetName.gb18030;
}

/// 无 BOM 的 UTF-16 启发式：ASCII 段在高位字节上全是 0。
///
/// 只在「零字节占比很高且几乎都落在同一侧」时才认，避免把某些
/// 二进制垃圾当成 UTF-16 解出一堆乱码。
String? _sniffUtf16(List<int> bytes) {
  final limit = bytes.length < 4096 ? bytes.length : 4096;
  if (limit < 8) return null;
  var zerosAtEven = 0;
  var zerosAtOdd = 0;
  for (var i = 0; i + 1 < limit; i += 2) {
    if (bytes[i] == 0) zerosAtEven++;
    if (bytes[i + 1] == 0) zerosAtOdd++;
  }
  final pairs = limit ~/ 2;
  // 中文 UTF-16 文本里 ASCII 标点/数字足够多，20% 是个宽松但安全的门槛。
  final threshold = pairs * 0.2;
  if (zerosAtOdd > threshold && zerosAtEven <= zerosAtOdd / 4) {
    return CharsetName.utf16le; // 低字节在前 → 高位（奇数位）是 0
  }
  if (zerosAtEven > threshold && zerosAtOdd <= zerosAtEven / 4) {
    return CharsetName.utf16be;
  }
  return null;
}

bool _isValidUtf8(List<int> bytes) {
  // 只抽前 32KB 校验：编码探测对长文件没必要全文扫，
  // 而局部合法的概率远小于「整篇都合法」。
  final limit = bytes.length < 32768 ? bytes.length : 32768;
  var i = 0;
  while (i < limit) {
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
    if (i + need >= limit) return true; // 截断在窗口边缘，不算错
    for (var k = 1; k <= need; k++) {
      if (bytes[i + k] & 0xC0 != 0x80) return false;
    }
    i += need + 1;
  }
  return true;
}

/// 字符下标 → 原始字节偏移的换算器。
///
/// 章节偏移必须是**字节**偏移（入库后按偏移重读文件），而正则匹配拿到的是
/// 字符下标；为几百万字的书建一整张映射表要多花几十 MB，
/// 所以这里只做「单调前进」的增量换算：分章本来就是从头扫到尾。
class ByteOffsetMapper {
  ByteOffsetMapper(this.text, this.charset, {this.baseOffset = 0})
    : _normalized = normalizeCharset(charset);

  final String text;
  final String charset;

  /// 文本首字符在原始文件里的字节偏移（跳过 BOM 后的位置）。
  final int baseOffset;

  final String _normalized;

  int _charPos = 0;
  int _bytePos = 0;

  /// 返回 [charIndex] 处的字节偏移。要求调用方基本单调（可回退，会重算）。
  int byteAt(int charIndex) {
    final target = charIndex.clamp(0, text.length);
    if (target < _charPos) {
      _charPos = 0;
      _bytePos = 0;
    }
    while (_charPos < target) {
      _bytePos += _byteWidth(_charPos);
      _charPos++;
    }
    return baseOffset + _bytePos;
  }

  /// 获取 [charIndex] 起始字符占用的字节数。
  int _byteWidth(int index) {
    final code = text.codeUnitAt(index);
    switch (_normalized) {
      case CharsetName.utf16le:
      case CharsetName.utf16be:
        return 2; // 代理对两个 code unit 各算 2 字节，合计 4，正好
      case CharsetName.gbk:
      case CharsetName.gb18030:
        return code < 0x80 ? 1 : 2;
      default:
        if (code < 0x80) return 1;
        if (code < 0x800) return 2;
        // 代理对：高位代理单独算 0，让 4 字节全落在第二个 code unit 上，
        // 这样 start 落在代理对中间时不会读到半个字符。
        if (code >= 0xD800 && code <= 0xDBFF) return 0;
        return 3;
    }
  }
}
