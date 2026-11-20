import 'dart:typed_data';

import 'package:legado_core/src/format/comic_parser.dart';
import 'package:legado_core/src/format/parsed_book.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

void main() {
  test('列出图片并按自然顺序排序（1,2,...,10 而不是 1,10,2）', () {
    final bytes = buildZip({
      for (var i = 1; i <= 10; i++) 'p$i.jpg': [0xFF, 0xD8, i],
    });
    final book = ComicParser().parse(bytes, fileName: '漫画.cbz');
    expect(book.format, BookFormat.comic);
    expect(book.pages.map((p) => p.name), [
      for (var i = 1; i <= 10; i++) 'p$i.jpg',
    ]);
  });

  test('过滤 __MACOSX/、.DS_Store、Thumbs.db 与非图片文件', () {
    final bytes = buildZip({
      '1.jpg': [0xFF, 0xD8, 1],
      '__MACOSX/._1.jpg': [0x00, 0x00],
      '__MACOSX/sub/2.jpg': [0x00, 0x00],
      '.DS_Store': [0x00, 0x00],
      'Thumbs.db': [0x00, 0x00],
      'info.txt': 'not an image'.codeUnits,
      '2.png': [0x89, 0x50, 0x4E, 0x47],
    });
    final book = ComicParser().parse(bytes);
    expect(book.pages.map((p) => p.name), ['1.jpg', '2.png']);
  });

  test('页可以按 zip 内路径取回原始字节', () {
    final bytes = buildZip({
      'page1.jpg': [0x11, 0x22, 0x33],
      'page2.jpg': [0x44, 0x55],
    });
    final book = ComicParser().parse(bytes);
    expect(book.pages[0].bytes(), [0x11, 0x22, 0x33]);
    expect(book.pages[1].bytes(), [0x44, 0x55]);
    expect(book.pages[0].size, 3);
  });

  test('每页同时生成对应章节（阅读器只需一套逻辑）', () {
    final bytes = buildZip({
      'a/1.jpg': [0x01],
      'a/2.jpg': [0x02],
    });
    final book = ComicParser().parse(bytes);
    expect(book.chapters, hasLength(2));
    expect(book.chapters[0].title, '第 1 页');
    expect(book.chapters[0].href, 'a/1.jpg');
    expect(book.chapters[1].index, 1);
  });

  test('rar 包抛 UnsupportedFormatException 并说明原因', () {
    final rar = Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0, 0]);
    expect(
      () => ComicParser().parse(rar, fileName: 'a.cbr'),
      throwsA(
        isA<UnsupportedFormatException>().having(
          (e) => e.reason,
          'reason',
          contains('zip'),
        ),
      ),
    );
  });

  test('7z 包抛 UnsupportedFormatException', () {
    final sevenZip = Uint8List.fromList([
      0x37,
      0x7A,
      0xBC,
      0xAF,
      0x27,
      0x1C,
      0,
      0,
    ]);
    expect(
      () => ComicParser().parse(sevenZip),
      throwsA(isA<UnsupportedFormatException>()),
    );
  });

  test('没有图片的 zip 抛 BookParseException', () {
    final bytes = buildZip({'readme.txt': 'hello'.codeUnits});
    expect(
      () => ComicParser().parse(bytes),
      throwsA(isA<BookParseException>()),
    );
  });

  test('自然排序：中文名与带前导零的编号', () {
    expect(naturalCompare('第1话.jpg', '第2话.jpg'), lessThan(0));
    expect(naturalCompare('第2话.jpg', '第10话.jpg'), lessThan(0));
    expect(naturalCompare('01.jpg', '1.jpg'), lessThan(0));
    expect(naturalCompare('a.jpg', 'a.jpg'), 0);
  });
}
