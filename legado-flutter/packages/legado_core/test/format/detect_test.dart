import 'dart:convert';
import 'dart:typed_data';

import 'package:legado_core/src/format/detect.dart';
import 'package:legado_core/src/format/parsed_book.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 格式识别的组合矩阵。
///
/// 这张表是"用户把文件改错名"的真实场景：下载站的 .txt 常常其实是 epub，
/// 而 .zip 可能是 epub 也可能是漫画，只能看内容。
void main() {
  group('扩展名优先', () {
    test('.txt → txt', () {
      expect(detect(utf8Bytes('第一章 测试'), 'a.txt'), BookFormat.txt);
    });

    test('.epub → epub', () {
      expect(detect(utf8Bytes('anything'), 'a.epub'), BookFormat.epub);
    });

    test('.umd → umd', () {
      expect(detect(utf8Bytes('anything'), 'a.umd'), BookFormat.umd);
    });

    test('.pdf → pdf', () {
      expect(detect(utf8Bytes('anything'), 'a.pdf'), BookFormat.pdf);
    });

    test('扩展名大小写不敏感、路径能带目录', () {
      expect(detect(utf8Bytes('x'), r'C:\books\A.TXT'), BookFormat.txt);
      expect(detect(utf8Bytes('x'), '/mnt/books/A.EPUB'), BookFormat.epub);
    });

    test('.cbz → comic', () {
      expect(detect(buildZip({'1.jpg': [1]}), 'a.cbz'), BookFormat.comic);
    });

    test('.zip 里是 epub 时识别为 epub（不能只看扩展名）', () {
      final epub = buildEpub2();
      expect(detect(epub, 'a.zip'), BookFormat.epub);
    });

    test('.txt 里其实是 epub 时按魔数纠正', () {
      final epub = buildEpub2();
      expect(detect(epub, 'a.txt'), BookFormat.epub);
    });
  });

  group('魔数', () {
    test('PDF 头 %PDF', () {
      expect(detect(utf8Bytes('%PDF-1.7\n...'), null), BookFormat.pdf);
    });

    test('UMD 魔数', () {
      expect(detect(buildUmd(), null), BookFormat.umd);
    });

    test('zip 里有 mimetype → epub', () {
      final zip = buildZip({
        'mimetype': utf8.encode('application/epub+zip'),
        'a.xhtml': utf8.encode('<html/>'),
      });
      expect(detect(zip, null), BookFormat.epub);
    });

    test('zip 里有 META-INF/container.xml → epub', () {
      final zip = buildZip({
        'META-INF/container.xml': utf8.encode('<container/>'),
      });
      expect(detect(zip, null), BookFormat.epub);
    });

    test('普通 zip → comic', () {
      final zip = buildZip({
        '1.jpg': [0xFF, 0xD8],
        '2.jpg': [0xFF, 0xD8],
      });
      expect(detect(zip, null), BookFormat.comic);
    });
  });

  group('无扩展名兜底', () {
    test('UTF-8 文本 → txt', () {
      expect(detect(utf8Bytes('第一章 起风\n正文'), null), BookFormat.txt);
    });

    test('GBK 文本 → txt', () {
      expect(detect(gbkBytes('第一章 起风\n正文'), null), BookFormat.txt);
    });

    test('UTF-16LE 带 BOM 的文本 → txt', () {
      expect(detect(utf16leBytes('第一章 起风'), null), BookFormat.txt);
    });

    test('二进制垃圾 → unknown', () {
      final junk = Uint8List.fromList(List.generate(200, (i) => i % 7));
      expect(detect(junk, null), BookFormat.unknown);
    });

    test('空数据 → unknown', () {
      expect(detect(Uint8List(0), null), BookFormat.unknown);
    });
  });
}
