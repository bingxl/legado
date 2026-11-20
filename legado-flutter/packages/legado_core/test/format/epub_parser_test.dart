import 'dart:convert';
import 'dart:typed_data';

import 'package:legado_core/src/format/epub_parser.dart';
import 'package:legado_core/src/format/parsed_book.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 字符串 → UTF-8 字节。
///
/// 千万别用 `codeUnits`：它对非 ASCII 返回 UTF-16 码元，
/// 塞进 zip 就是非法 UTF-8，解析出来是乱码（这次就踩了）。
extension on String {
  List<int> get bytes => utf8.encode(this);
}

/// EPUB 的兼容性清单。
///
/// 每条用例对应一个真实见过的畸形：
/// 大小写不一致、URL 编码文件名、xhtml 不是合法 XML、一个文件塞一整卷。
void main() {
  group('EPUB2 (toc.ncx)', () {
    test('读取标题与作者', () {
      final book = EpubParser().parse(buildEpub2());
      expect(book.format, BookFormat.epub);
      expect(book.title, '测试之书');
      expect(book.author, '张三');
    });

    test('ncx 目录映射成章节，顺序与 ncx 一致', () {
      final book = EpubParser().parse(buildEpub2());
      expect(book.chapters.map((c) => c.title), ['第一章 起风', '第二章 落雨']);
      expect(book.chapters.map((c) => c.index), [0, 1]);
    });

    test('章节 href 指向 opf 目录下的资源', () {
      final book = EpubParser().parse(buildEpub2());
      expect(book.chapters.first.href, 'OEBPS/chapter1.xhtml');
      expect(book.chapters.first.resource, 'OEBPS/chapter1.xhtml');
      expect(book.chapters.first.fragment, isNull);
    });

    test('正文去掉 script/style 与标题标签，保留段落', () {
      final book = EpubParser().parse(buildEpub2());
      final content = book.chapters.first.content ?? '';
      expect(content, contains('第一章 起风'));
      expect(content, contains('正文段落'));
      expect(content, isNot(contains('var a=1')));
      expect(content, isNot(contains('color:red')));
    });

    test('简介里的 HTML 标签被去掉', () {
      final book = EpubParser().parse(buildEpub2());
      expect(book.metadata['intro'], '一段简介');
    });

    test('元信息带语言与标识符', () {
      final book = EpubParser().parse(buildEpub2());
      expect(book.metadata['language'], 'zh-CN');
      expect(book.metadata['identifier'], 'urn:uuid:12345678');
    });
  });

  group('EPUB3 (nav.xhtml)', () {
    test('从 nav 读取目录并拍平嵌套层级', () {
      final book = EpubParser().parse(buildEpub3Nav());
      expect(book.title, 'EPUB3 之书');
      expect(book.chapters.map((c) => c.title), [
        '第一卷 少年',
        '第一章 出发',
        '第二章 抵达',
        '第二卷 归来',
        '第三章 旧地',
      ]);
    });

    test('卷标题标记为 isVolume 且没有正文', () {
      final book = EpubParser().parse(buildEpub3Nav());
      expect(book.chapters[0].isVolume, isTrue);
      expect(book.chapters[0].content, isNull);
      expect(book.chapters[1].isVolume, isFalse);
    });

    test('nav 的相对路径相对于 nav 文件解析', () {
      final book = EpubParser().parse(buildEpub3Nav());
      expect(book.chapters[1].href, 'EPUB/text/ch1.xhtml');
      expect(book.chapters[1].content, contains('第一章 出发的正文'));
    });
  });

  group('畸形与兜底', () {
    test('没有 ncx 也没有 nav 时按 spine 兜底，标题取 <title>', () {
      final bytes = buildZip({
        'mimetype': 'application/epub+zip'.bytes,
        'META-INF/container.xml': _container('content.opf').bytes,
        'content.opf': _opfNoToc().bytes,
        'a.xhtml': _xhtml('第一节').bytes,
        'b.xhtml': _xhtml('第二节').bytes,
      });
      final book = EpubParser().parse(bytes);
      expect(book.chapters, hasLength(2));
      expect(book.chapters.map((c) => c.title), ['第一节', '第二节']);
    });

    test('zip 内文件名大小写不一致也能找到资源', () {
      final bytes = buildZip({
        'MIMETYPE': 'application/epub+zip'.bytes,
        'meta-inf/CONTAINER.XML': _container('OEBPS/Content.opf').bytes,
        'OEBPS/Content.opf': _opfUpper().bytes,
        'OEBPS/Chapter1.XHTML': _xhtml('大写文件').bytes,
      });
      final book = EpubParser().parse(bytes);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.content, contains('大写文件'));
    });

    test('URL 编码的中文文件名能被解析', () {
      final bytes = buildZip({
        'mimetype': 'application/epub+zip'.bytes,
        'META-INF/container.xml': _container('content.opf').bytes,
        'content.opf': _opfEncodedName().bytes,
        '第一章 起风.xhtml': _xhtml('中文文件名').bytes,
      });
      final book = EpubParser().parse(bytes);
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.content, contains('中文文件名'));
    });

    test('xhtml 不是合法 XML（未闭合 br、裸 &）也能取正文', () {
      final badXhtml = '<html><body><p>第一段<br>第二段<span>第三段</span>'
          '<p>甲 & 乙</body></html>';
      final bytes = buildZip({
        'mimetype': 'application/epub+zip'.bytes,
        'META-INF/container.xml': _container('content.opf').bytes,
        'content.opf': _opfSingle('bad.xhtml', '坏文件').bytes,
        'bad.xhtml': badXhtml.bytes,
      });
      final book = EpubParser().parse(bytes);
      expect(book.chapters.single.content, contains('第二段'));
      expect(book.chapters.single.content, contains('甲'));
    });

    test('没有 container.xml 时扫 zip 找 .opf', () {
      final bytes = buildZip({
        'mimetype': 'application/epub+zip'.bytes,
        'content.opf': _opfSingle('a.xhtml', '无容器').bytes,
        'a.xhtml': _xhtml('无容器').bytes,
      });
      final book = EpubParser().parse(bytes);
      expect(book.chapters.single.content, contains('无容器'));
    });

    test('不是 zip 时抛 BookParseException', () {
      expect(
        () => EpubParser().parse(Uint8List.fromList('not a zip'.bytes)),
        throwsA(isA<BookParseException>()),
      );
    });

    test('一个 xhtml 内用锚点分章时，各章内容不串台', () {
      final bytes = buildAnchoredEpub();
      final book = EpubParser().parse(bytes);
      expect(book.chapters, hasLength(2));
      expect(book.chapters[0].content, contains('第一章正文'));
      expect(book.chapters[0].content, isNot(contains('第二章正文')));
      expect(book.chapters[1].content, contains('第二章正文'));
      expect(book.chapters[1].content, isNot(contains('第一章正文')));
    });
  });
}

// ------------------------------------------------------------------ 素材

String _container(String opfPath) =>
    '<?xml version="1.0"?><container version="1.0" '
    'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
    '<rootfile full-path="$opfPath" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _xhtml(String text) =>
    '<html><body><h1>$text</h1><p>$text正文</p></body></html>';

String _opfNoToc() =>
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
    'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>无目录</dc:title></metadata><manifest>'
    '<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>'
    '</manifest><spine><itemref idref="a"/><itemref idref="b"/></spine>'
    '</package>';

String _opfUpper() =>
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
    'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>大写</dc:title></metadata><manifest>'
    '<item id="a" href="Chapter1.XHTML" media-type="application/xhtml+xml"/>'
    '</manifest><spine><itemref idref="a"/></spine></package>';

String _opfEncodedName() =>
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
    'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>编码名</dc:title></metadata><manifest>'
    '<item id="a" href="%E7%AC%AC%E4%B8%80%E7%AB%A0%20%E8%B5%B7%E9%A3%8E.xhtml" '
    'media-type="application/xhtml+xml"/>'
    '</manifest><spine><itemref idref="a"/></spine></package>';

String _opfSingle(String href, String title) =>
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
    'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:title>$title</dc:title></metadata><manifest>'
    '<item id="a" href="$href" media-type="application/xhtml+xml"/>'
    '</manifest><spine><itemref idref="a"/></spine></package>';

/// 一个 xhtml 里用 `id` 锚点分两章，目录两条都指向同一文件。
Uint8List buildAnchoredEpub() {
  const opf = '<?xml version="1.0"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="2.0">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>锚点分章</dc:title></metadata><manifest>'
      '<item id="all" href="all.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
      '</manifest><spine toc="ncx"><itemref idref="all"/></spine></package>';
  const ncx = '<?xml version="1.0"?>'
      '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
      '<navMap>'
      '<navPoint id="n1"><navLabel><text>第一章</text></navLabel>'
      '<content src="all.xhtml#c1"/></navPoint>'
      '<navPoint id="n2"><navLabel><text>第二章</text></navLabel>'
      '<content src="all.xhtml#c2"/></navPoint>'
      '</navMap></ncx>';
  const all = '<html><body>'
      '<h2 id="c1">第一章</h2><p>第一章正文</p>'
      '<h2 id="c2">第二章</h2><p>第二章正文</p>'
      '</body></html>';
  return buildZip({
    'mimetype': 'application/epub+zip'.bytes,
    'META-INF/container.xml': _container('content.opf').bytes,
    'content.opf': opf.bytes,
    'toc.ncx': ncx.bytes,
    'all.xhtml': all.bytes,
  });
}
