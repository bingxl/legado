import 'dart:convert';
import 'dart:typed_data';

import 'package:gbk_codec/gbk_codec.dart' show gbk_bytes;
import 'package:legado_core/src/net/charset.dart';
import 'package:test/test.dart';

void main() {
  const chinese = '中文测试';

  List<int> gbkBytes(String s) => gbk_bytes.encoder.convert(s);

  group('无声明时的启发式', () {
    test('纯 UTF-8 正常解', () {
      expect(decode(utf8.encode(chinese)), chinese);
    });

    test('UTF-8 无声明（含中文）能识别', () {
      final bytes = utf8.encode('第一章 风起');
      expect(decode(bytes), '第一章 风起');
    });

    test('GBK 无声明走启发式兜底', () {
      final bytes = gbkBytes(chinese);
      expect(isValidUtf8(bytes), isFalse);
      expect(decode(bytes), chinese);
    });

    test('纯 ASCII 不会误判', () {
      expect(decode(utf8.encode('hello world')), 'hello world');
    });

    test('空字节返回空串', () {
      expect(decode(const <int>[]), '');
    });
  });

  group('声明优先级', () {
    test('meta charset 优先于启发式', () {
      final head = utf8.encode('<html><head><meta charset="gbk"></head><body>');
      final bytes = [...head, ...gbkBytes(chinese)];
      expect(decode(bytes), contains('<html>'));
      expect(decode(bytes), contains(chinese));
    });

    test('meta http-equiv content-type 也认', () {
      final head = utf8.encode(
        '<meta http-equiv="Content-Type" content="text/html; charset=gbk">',
      );
      final bytes = [...head, ...gbkBytes(chinese)];
      expect(decode(bytes), contains(chinese));
    });

    test('响应头 charset 优先于 meta', () {
      // 正文是 GBK，meta 骗人说是 UTF-8，响应头说是 GBK —— 以响应头为准。
      final head = utf8.encode('<meta charset="utf-8">');
      final bytes = [...head, ...gbkBytes(chinese)];
      final text = decode(
        bytes,
        contentType: 'text/html; charset=gbk',
      );
      expect(text, contains(chinese));
    });

    test('显式 declaredCharset 压过响应头', () {
      final bytes = gbkBytes(chinese);
      expect(
        decode(bytes, declaredCharset: 'gbk', contentType: 'text/html; charset=utf-8'),
        chinese,
      );
    });

    test('xml encoding 声明也认', () {
      final head = utf8.encode('<?xml version="1.0" encoding="gbk"?><rss>');
      final bytes = [...head, ...gbkBytes(chinese)];
      expect(decode(bytes), contains(chinese));
    });

    test('没有 meta 时 sniffFromHtml 返回 null', () {
      expect(sniffFromHtml(utf8.encode('<html><body>hi</body></html>')), isNull);
    });
  });

  group('BOM 与其他编码', () {
    test('UTF-8 BOM 被去掉', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode(chinese)];
      expect(decode(bytes), chinese);
    });

    test('UTF-16LE BOM', () {
      final text = '第一章';
      final builder = BytesBuilder();
      builder.add([0xFF, 0xFE]);
      for (final unit in text.codeUnits) {
        builder.add([unit & 0xFF, (unit >> 8) & 0xFF]);
      }
      expect(decode(builder.toBytes()), text);
    });

    test('UTF-16BE BOM', () {
      final text = 'AB中文';
      final builder = BytesBuilder();
      builder.add([0xFE, 0xFF]);
      for (final unit in text.codeUnits) {
        builder.add([(unit >> 8) & 0xFF, unit & 0xFF]);
      }
      expect(decode(builder.toBytes()), text);
    });

    test('ISO-8859-1 声明可解', () {
      final bytes = latin1.encode('café');
      expect(decode(bytes, declaredCharset: 'iso-8859-1'), 'café');
    });

    test('未知编码名不抛异常', () {
      final bytes = utf8.encode('随便');
      expect(() => decode(bytes, declaredCharset: 'x-unknown-enc'), returnsNormally);
    });
  });

  group('工具函数', () {
    test('isValidUtf8 判定正确', () {
      expect(isValidUtf8(utf8.encode('中文')), isTrue);
      expect(isValidUtf8(gbkBytes('中文')), isFalse);
      expect(isValidUtf8(const [0xFF]), isFalse);
      expect(isValidUtf8(const []), isTrue);
    });

    test('normalizeCharset 归并别名', () {
      expect(normalizeCharset('GB2312'), 'gbk');
      expect(normalizeCharset('gb18030'), 'gbk');
      expect(normalizeCharset(' UTF8 '), 'utf-8');
      expect(normalizeCharset('charset=GBK'), 'gbk');
      expect(normalizeCharset(null), '');
    });

    test('charsetFromContentType', () {
      expect(charsetFromContentType('text/html; charset="UTF-8"'), 'utf-8');
      expect(charsetFromContentType('text/html;charset=gbk'), 'gbk');
      expect(charsetFromContentType('text/html'), isNull);
      expect(charsetFromContentType(null), isNull);
    });

    test('encode 与 decode 对称（GBK）', () {
      final bytes = encode(chinese, charset: 'gbk');
      expect(decode(bytes), chinese);
    });

    test('encode UTF-8 与 charset 为空等价', () {
      expect(encode('abc'), utf8.encode('abc'));
      expect(encode('abc', charset: 'utf-8'), utf8.encode('abc'));
    });
  });
}
