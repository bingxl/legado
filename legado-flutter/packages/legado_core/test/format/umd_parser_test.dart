import 'dart:typed_data';

import 'package:legado_core/src/format/parsed_book.dart';
import 'package:legado_core/src/format/umd_parser.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// UMD 是二进制格式，测试素材用 `fixtures.buildUmd` 按原版 writer 的结构现造，
/// 这样"读"与"写"互相印证：只测读会掩盖两边同时理解错的情况。
void main() {
  test('读取书名、作者与章节', () {
    final book = UmdParser().parse(
      buildUmd(chapterTitles: ['第一章 开始', '第二章 继续']),
    );
    expect(book.format, BookFormat.umd);
    expect(book.title, 'UMD 测试书');
    expect(book.author, '王五');
    expect(book.chapters.map((c) => c.title), ['第一章 开始', '第二章 继续']);
  });

  test('正文按章节切分且内容正确', () {
    final book = UmdParser().parse(
      buildUmd(
        chapterTitles: ['第一章 开始', '第二章 继续'],
        contents: ['第一章的正文。第二句。', '第二章的正文。'],
      ),
    );
    expect(book.chapters[0].content, '第一章的正文。第二句。');
    expect(book.chapters[1].content, '第二章的正文。');
  });

  test('段落分隔符 U+2029 被换成换行', () {
    final book = UmdParser().parse(
      buildUmd(
        chapterTitles: ['唯一章'],
        contents: ['第一段。\u2029第二段。'],
      ),
    );
    expect(book.chapters.single.content, '第一段。\n第二段。');
  });

  test('多章偏移正确（不是把所有正文塞进第一章）', () {
    final book = UmdParser().parse(
      buildUmd(
        chapterTitles: ['A', 'B', 'C'],
        contents: ['aaa', 'bbb', 'ccc'],
      ),
    );
    expect(book.chapters.map((c) => c.content), ['aaa', 'bbb', 'ccc']);
  });

  test('魔数不对时抛 BookParseException', () {
    expect(
      () => UmdParser().parse(Uint8List.fromList(List.filled(32, 0x41))),
      throwsA(isA<BookParseException>()),
    );
  });

  test('文件被截断时抛 BookParseException 而不是越界崩溃', () {
    final full = buildUmd();
    // 砍掉结尾段的数据部分：段头还在，长度对不上，必须报错而不是继续读。
    final truncated = Uint8List.sublistView(full, 0, full.length - 4);
    expect(
      () => UmdParser().parse(truncated),
      throwsA(isA<BookParseException>()),
    );
  });

  test('带许可证段（加密）时抛 UnsupportedFormatException', () {
    final encrypted = buildUmd(encrypted: true);
    expect(
      () => UmdParser().parse(encrypted),
      throwsA(isA<UnsupportedFormatException>()),
    );
  });
}
