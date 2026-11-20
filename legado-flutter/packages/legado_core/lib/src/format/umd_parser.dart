import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'parsed_book.dart';

/// UMD（掌上书苑）解析器。
///
/// 格式没有官方文档，实现依据是原版内置的 `umdlib`（`modules/book/.../umdlib`）：
///
/// ```text
/// 89 9B 9A DE            魔数（0xDE9A9B89，小端）
/// 每段: '#' + type(2,LE) + flag(1) + len(1) + data(len-5)
/// 段后可跟若干附加段: '$' + check(4,LE) + len(4,LE) + data(len-9)
/// ```
///
/// 关键在于**附加段的校验数**：同一个章节块里，偏移表/标题表的校验数与
/// 段头的校验数相同，而正文块的校验数不同。原版就是靠这个区分"这是标题"
/// 还是"这是正文"，不懂这一点会把二进制正文当标题解出一堆乱码。
class UmdParser {
  /// UMD 魔数（小端写入后读出来的 int 值）。
  static const magic = 0xDE9A9B89;

  ParsedBook parse(Uint8List bytes) {
    if (bytes.length < 16) {
      throw BookParseException('文件太小，不是 UMD');
    }
    final reader = _ByteReader(bytes);
    if (reader.u32le() != magic) {
      throw BookParseException('UMD 魔数不匹配');
    }

    var title = '';
    var author = '';
    var bookType = '';
    var encrypted = false;
    var contentLength = -1;
    var chaptersCount = 0;
    var checkNumber = -1;

    final offsets = <int>[];
    final titles = <String>[];
    final content = BytesBuilder(copy: false);
    Uint8List? cover;

    while (!reader.isDone) {
      if (reader.u8() != 0x23) break; // '#'
      final type = reader.u16le();
      final flag = reader.u8();
      final dataLength = reader.u8() - 5;
      if (dataLength < 0 || reader.remaining < dataLength) {
        throw BookParseException('UMD 分段长度非法（type=$type, flag=$flag）');
      }

      switch (type) {
        case 0x01: // 文件类型
          reader.u8();
          reader.skip(2);
        case 0x02: // 书名
          title = _utf16(reader.take(dataLength));
        case 0x03: // 作者
          author = _utf16(reader.take(dataLength));
        case 0x07: // 小说类型
          bookType = _utf16(reader.take(dataLength));
        case 0x0B: // 正文总长度（解压后）
          contentLength = reader.u32le();
        case 0x81: // 正文块索引
        case 0x83: // 章偏移表
        case 0x84: // 章标题表
          checkNumber = reader.u32le();
        case 0x82: // 封面：body = 1 字节 + 4 字节校验数
          reader.u8();
          checkNumber = reader.u32le();
        case 0xF0: // CDS key：正常文件不会有，出现即视为 DRM
          encrypted = true;
          reader.skip(dataLength);
        case 0xF1:
          // 这一段的语义是"许可证"，但正文块的结尾也用 0xF1 占位（16 个 0）。
          // 所以不能见到 0xF1 就判加密——必须看密钥是不是真有内容。
          final key = reader.take(dataLength);
          if (key.any((b) => b != 0)) encrypted = true;
        case 0x0C: // 文件结束
          reader.skip(dataLength);
        default:
          reader.skip(dataLength);
      }

      // 附加段：可能连续多个，直到遇到下一个 '#'。
      while (!reader.isDone && reader.peek() == 0x24) {
        reader.u8(); // '$'
        final addCheck = reader.u32le();
        final rawLength = reader.u32le() - 9;
        if (rawLength < 0 || reader.remaining < rawLength) {
          throw BookParseException('UMD 附加段长度非法（type=$type）');
        }
        final sameBlock = addCheck == checkNumber;
        switch (type) {
          case 0x83:
            if (sameBlock) {
              chaptersCount = rawLength ~/ 4;
              for (var i = 0; i < chaptersCount; i++) {
                offsets.add(reader.u32le());
              }
            } else {
              reader.skip(rawLength);
            }
          case 0x84:
            if (sameBlock) {
              _readTitles(reader, chaptersCount, titles);
            } else {
              // 校验数不同的 0x84 附加段就是正文块（原版靠这个区分）。
              _appendContent(reader, rawLength, content);
            }
          case 0x82:
            cover = reader.take(rawLength);
          case 0x81:
            reader.skip(rawLength);
          default:
            reader.skip(rawLength);
        }
      }
    }

    if (encrypted) {
      throw UnsupportedFormatException(
        '这本 UMD 已加密，无法读取',
        reason: '原版 legado 同样读不了，需要先用 UMD 解密工具处理',
      );
    }

    final text = _utf16(content.takeBytes());
    final chapters = _buildChapters(
      titles: titles,
      offsets: offsets,
      text: text,
      totalLength: contentLength,
    );
    if (chapters.isEmpty) {
      throw BookParseException('UMD 里没有可读的正文');
    }

    return ParsedBook(
      title: title.isNotEmpty ? title : '未命名',
      author: author.isEmpty ? null : author,
      format: BookFormat.umd,
      chapters: chapters,
      metadata: {
        if (bookType.isNotEmpty) 'kind': bookType,
        'charset': 'utf-16le',
      },
      coverBytes: cover != null && cover.length > 200 ? cover : null,
    );
  }

  /// 正文块：zlib 压缩的 UTF-16LE 字节流，直接拼到正文缓冲里。
  void _appendContent(_ByteReader reader, int length, BytesBuilder out) {
    final compressed = reader.take(length);
    try {
      out.add(ZLibDecoder().decodeBytes(compressed));
    } catch (e) {
      throw BookParseException('UMD 正文解压失败', cause: e);
    }
  }

  /// 标题表：每个标题是 `len(1) + UTF-16LE`。
  void _readTitles(_ByteReader reader, int count, List<String> out) {
    for (var i = 0; i < count; i++) {
      if (reader.isDone) break;
      final len = reader.u8();
      if (reader.remaining < len) break;
      out.add(_utf16(reader.take(len)));
    }
  }

  List<ParsedChapter> _buildChapters({
    required List<String> titles,
    required List<int> offsets,
    required String text,
    required int totalLength,
  }) {
    // UTF-16 一个码元 2 字节，按字节偏移切字符串要换算成字符下标；
    // 0x2029（段落分隔符）已在 _utf16 里换成 '\n'，长度不变，可直接换算。
    final charOffsets = <int>[
      for (final o in offsets) (o ~/ 2).clamp(0, text.length),
    ];
    final totalChars = totalLength > 0
        ? (totalLength ~/ 2).clamp(0, text.length)
        : text.length;

    if (titles.isEmpty) {
      if (text.trim().isEmpty) return const [];
      return [
        ParsedChapter(title: '正文', index: 0, content: text.trim()),
      ];
    }

    final chapters = <ParsedChapter>[];
    for (var i = 0; i < titles.length; i++) {
      final start = i < charOffsets.length ? charOffsets[i] : 0;
      final end = i + 1 < charOffsets.length ? charOffsets[i + 1] : totalChars;
      final body = start < end && end <= text.length
          ? text.substring(start, end)
          : '';
      chapters.add(
        ParsedChapter(
          title: titles[i].trim(),
          index: i,
          content: body.trim(),
        ),
      );
    }
    return chapters;
  }

  /// UTF-16LE → String，并把 UMD 的段落分隔符 0x2029 换成换行。
  static String _utf16(Uint8List bytes) {
    final units = <int>[];
    final limit = bytes.length & ~1;
    for (var i = 0; i < limit; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    // String.fromCharCodes 会把代理对正确合成一个字符。
    return String.fromCharCodes(units).replaceAll('\u2029', '\n');
  }
}

class _ByteReader {
  _ByteReader(this.data);

  final Uint8List data;
  int _pos = 0;

  bool get isDone => _pos >= data.length;

  int get remaining => data.length - _pos;

  int peek() => isDone ? -1 : data[_pos];

  int u8() {
    if (_pos >= data.length) throw BookParseException('UMD 提前结束');
    return data[_pos++];
  }

  int u16le() {
    final lo = u8();
    final hi = u8();
    return lo | (hi << 8);
  }

  int u32le() {
    final b0 = u8();
    final b1 = u8();
    final b2 = u8();
    final b3 = u8();
    // 用乘法避免 << 24 在 32 位上溢出成负数（Dart int 是 64 位，安全但显式更清楚）。
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
  }

  Uint8List take(int length) {
    if (length <= 0) return Uint8List(0);
    if (_pos + length > data.length) throw BookParseException('UMD 提前结束');
    final result = Uint8List.sublistView(data, _pos, _pos + length);
    _pos += length;
    return result;
  }

  void skip(int length) {
    if (length <= 0) return;
    _pos = (_pos + length).clamp(0, data.length);
  }
}
