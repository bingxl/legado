import 'dart:typed_data';

import 'package:legado_core/src/format/format.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 门面测试：确认"给字节 + 文件名"就能拿到正确的解析结果，
/// 并且错误都被翻译成调用方能处理的类型。
void main() {
  test('txt：按文件名识别并解析出章节', () async {
    final book = await BookParser.parse(
      utf8Bytes(fiveChapterBook()),
      fileName: '测试书.txt',
    );
    expect(book.format, BookFormat.txt);
    expect(book.title, '测试书');
    expect(book.chapters, hasLength(5));
    expect(book.chapters.first.readContent(), contains('天色渐暗'));
  });

  test('txt：显式指定编码时按指定编码解码', () async {
    final book = await BookParser.parse(
      gbkBytes(fiveChapterBook()),
      fileName: 'a.txt',
      charset: 'gbk',
    );
    expect(book.chapters.first.title, '第一章 山雨欲来');
  });

  test('epub：解析出元信息与章节正文', () async {
    final book = await BookParser.parse(buildEpub2(), fileName: 'a.epub');
    expect(book.format, BookFormat.epub);
    expect(book.title, '测试之书');
    expect(book.chapters.first.content, contains('正文段落'));
  });

  test('umd：解析出章节', () async {
    final book = await BookParser.parse(buildUmd(), fileName: 'a.umd');
    expect(book.format, BookFormat.umd);
    expect(book.chapters, hasLength(2));
  });

  test('comic：页数与页字节', () async {
    final zip = buildZip({
      for (var i = 1; i <= 3; i++) '$i.jpg': [0x0F, i],
    });
    final book = await BookParser.parse(zip, fileName: 'a.cbz');
    expect(book.format, BookFormat.comic);
    expect(book.pages, hasLength(3));
    expect(book.pages.first.name, '1.jpg');
  });

  test('pdf：解析出页数与分段章节', () async {
    // 最小可用的 PDF 结构：一段 Pages 树声明 23 页，外加一个 Page 对象。
    final pdf = utf8Bytes(
      '%PDF-1.7\n'
      '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n'
      '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 23>>endobj\n'
      '3 0 obj<</Type/Page/Parent 2 0 R>>endobj\n'
      'trailer<</Root 1 0 R>>\n%%EOF',
    );
    final book = await BookParser.parse(pdf, fileName: '扫描版.pdf');
    expect(book.format, BookFormat.pdf);
    expect(book.title, '扫描版');
    expect(book.metadata['pageCount'], '23');
    // 每 10 页一章，23 页 → 3 段（10/10/3）。
    expect(book.chapters, hasLength(3));
    expect(book.chapters[0].start, 0);
    expect(book.chapters[0].end, 10);
    expect(book.chapters[2].start, 20);
    expect(book.chapters[2].end, 23);
    expect(book.chapters.first.title, '分段_1');
  });

  test('pdf：没有 Pages 树时按 Page 对象数兜底', () async {
    final pdf = utf8Bytes(
      '%PDF-1.4\n1 0 obj<</Type/Page>>endobj\n2 0 obj<</Type/Page>>endobj\n%%EOF',
    );
    final book = await BookParser.parse(pdf, fileName: 'a.pdf');
    expect(book.metadata['pageCount'], '2');
    expect(book.chapters, hasLength(1));
  });

  test('pdf：元数据里的 Title/Author 能被读出', () async {
    final pdf = utf8Bytes(
      '%PDF-1.7\n'
      '1 0 obj<</Type/Pages/Count 1>>endobj\n'
      'trailer<</Info<</Title (\\345\\244\\252\\344\\271\\246\\347\\273\\224)/Author (Legado)>>>>\n%%EOF',
    );
    final book = await BookParser.parse(pdf, fileName: 'a.pdf');
    expect(book.author, 'Legado');
    // Title 是 PDFDocEncoding 的八进制转义，按 Latin-1 解出中文 UTF-8 字节，
    // 这里只验证「没被转义序列打乱」——展示由 UI 决定。
    expect(book.title, isNot(contains('\\345')));
  });

  test('无法识别：抛 UnsupportedFormatException 并带上文件名', () async {
    await expectLater(
      BookParser.parse(Uint8List.fromList(List.filled(64, 0x01)), fileName: 'x.bin'),
      throwsA(
        isA<UnsupportedFormatException>().having(
          (e) => e.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
  });

  test('空文件：抛 BookParseException', () async {
    await expectLater(
      BookParser.parse(Uint8List(0), fileName: 'a.txt'),
      throwsA(isA<BookParseException>()),
    );
  });
}
