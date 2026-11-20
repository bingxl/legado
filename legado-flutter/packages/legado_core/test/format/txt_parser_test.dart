import 'dart:typed_data';

import 'package:legado_core/src/format/parsed_book.dart';
import 'package:legado_core/src/format/text_codec.dart';
import 'package:legado_core/src/format/txt_parser.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// TXT 解析的边界清单。
///
/// 这里刻意不用"真书"当素材：章节数、偏移、编码都能精确控制，
/// 失败时一眼能看出是规则问题还是偏移问题。
void main() {
  group('UTF-8 常规分章', () {
    test('五章中文文本识别出 5 章', () {
      final book = TxtParser().parse(utf8Bytes(fiveChapterBook()));
      expect(book.format, BookFormat.txt);
      expect(book.chapters, hasLength(5));
    });

    test('章节标题与原文一致且顺序正确', () {
      final book = TxtParser().parse(utf8Bytes(fiveChapterBook()));
      expect(book.chapters.map((c) => c.title), [
        '第一章 山雨欲来',
        '第二章 夜行',
        '第三章 旧事',
        '第四章 长街',
        '第五章 归途',
      ]);
      expect(book.chapters.map((c) => c.index), [0, 1, 2, 3, 4]);
    });

    test('contentOf 返回正文且不含标题行', () {
      final bytes = utf8Bytes(fiveChapterBook());
      final parser = TxtParser();
      final book = parser.parse(bytes);
      final body = parser.contentOf(book.chapters[1]);
      expect(body, contains('夜里没有月亮'));
      expect(body, isNot(contains('第二章 夜行')));
      expect(body, isNot(contains('第一章')));
    });

    test('start/end 是字节偏移，可按偏移切回原文', () {
      final bytes = utf8Bytes(fiveChapterBook());
      final book = TxtParser().parse(bytes);
      for (final chapter in book.chapters) {
        final raw = decodeRange(
          bytes,
          chapter.start!,
          chapter.end!,
          'utf-8',
        );
        expect(raw.trimLeft().startsWith(chapter.title), isTrue,
            reason:
                '${chapter.title} 的偏移切出来的开头是: '
                '${raw.substring(0, raw.length < 12 ? raw.length : 12)}');
      }
    });

    test('偏移首尾相接：上一章 end == 下一章 start', () {
      final book = TxtParser().parse(utf8Bytes(fiveChapterBook()));
      for (var i = 1; i < book.chapters.length; i++) {
        expect(book.chapters[i].start, book.chapters[i - 1].end);
      }
      expect(book.chapters.last.end, utf8Bytes(fiveChapterBook()).length);
    });
  });

  group('编码', () {
    test('GBK 文本解出的章节与 UTF-8 完全一致', () {
      final utf8Book = TxtParser().parse(utf8Bytes(fiveChapterBook()));
      final gbkBook = TxtParser(charset: 'gbk').parse(gbkBytes(fiveChapterBook()));
      expect(gbkBook.chapters.map((c) => c.title),
          utf8Book.chapters.map((c) => c.title));
    });

    test('未指定编码时 GBK 能被探测出来', () {
      final parser = TxtParser();
      final book = parser.parse(
        gbkBytes(fiveChapterBook()),
        fileName: '测试.txt',
      );
      expect(parser.usedCharset, 'gb18030');
      expect(book.chapters, hasLength(5));
      expect(parseCharset(book), isNot('utf-8'));
    });

    test('UTF-16LE 带 BOM 可解析', () {
      final book = TxtParser().parse(utf16leBytes(fiveChapterBook()));
      expect(book.chapters, hasLength(5));
      expect(book.chapters.first.title, '第一章 山雨欲来');
    });

    test('UTF-8 BOM 被跳过，第一章偏移从 3 开始', () {
      final withBom = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8Bytes(fiveChapterBook()),
      ]);
      final book = TxtParser().parse(withBom);
      expect(book.chapters.first.start, 3);
      expect(book.chapters.first.title, '第一章 山雨欲来');
    });

    test('BOM 不会跑进正文', () {
      final withBom = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8Bytes(fiveChapterBook()),
      ]);
      final parser = TxtParser();
      final book = parser.parse(withBom);
      final body = parser.contentOf(book.chapters.first);
      expect(body.codeUnitAt(0), isNot(0xFEFF));
      expect(body, startsWith('天色渐暗'));
    });
  });

  group('换行与排版', () {
    test('CRLF 不影响分章', () {
      final book = TxtParser().parse(
        utf8Bytes(fiveChapterBook(newline: '\r\n')),
      );
      expect(book.chapters, hasLength(5));
      expect(book.chapters[2].title, '第三章 旧事');
    });

    test('超长标题行 (>40 字) 不被当成章节', () {
      final longTitle = '第一章 ${'很长的标题' * 12}';
      final text = '$longTitle\n　　${'正文内容。' * 20}\n';
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '正文');
    });

    test('正文里提到"第三章"不会误判为标题', () {
      final text = [
        '第一章 起风',
        '　　他翻到第三章看了看，又合上了书，屋外的雨声更密了。',
        '　　这一夜很长，长得像一条没有尽头的走廊，风一直在吹。',
        '',
        '第二章 落雨',
        '　　雨停的时候，天已经亮了，院子里积了薄薄一层水。',
        '　　他把书放回架子上，出门去了。',
      ].join('\n');
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters, hasLength(2));
      expect(book.chapters.map((c) => c.title), ['第一章 起风', '第二章 落雨']);
    });
  });

  group('结构与兜底', () {
    test('无章节标记时整本当一章', () {
      final text = '${'这是一段没有任何章节标记的正文。' * 30}\n';
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '正文');
      expect(book.chapters.first.start, 0);
      expect(book.chapters.first.end, utf8Bytes(text).length);
    });

    test('只有一个章节标题时只有一章（不额外造前言）', () {
      final text = '第一章 唯一\n　　${'唯一一章的正文。' * 20}\n';
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters, hasLength(1));
      expect(book.chapters.first.title, '第一章 唯一');
    });

    test('首个标题之前的内容变成"前言"', () {
      final text = [
        '测试之书',
        '作者：某人',
        '',
        '第一章 起风',
        '　　风从山口灌进来，吹得旗子啪啪作响，他一言不发。',
        '　　远处有人在喊他的名字。',
        '',
        '第二章 落雨',
        '　　雨点砸在瓦上，声音密得像有人在屋顶上跑。',
        '　　他把窗关上，屋里一下子安静了。',
      ].join('\n');
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters.first.title, '前言');
      expect(book.chapters, hasLength(3));
    });

    test('目录页回声被丢弃，只留正文里的真章节', () {
      final text = [
        '目录',
        '第一章 起风',
        '第二章 落雨',
        '第三章 转晴',
        '',
        '第一章 起风',
        '　　风从山口灌进来，吹得旗子啪啪作响，他一言不发。',
        '　　远处有人在喊他的名字，声音被风撕成碎片。',
        '',
        '第二章 落雨',
        '　　雨点砸在瓦上，声音密得像有人在屋顶上跑。',
        '　　他把窗关上，屋里一下子安静下来，只剩灯芯的响。',
        '',
        '第三章 转晴',
        '　　云散开的时候，山尖先亮了起来，然后是整片林子。',
        '　　他背起包，往山下走。',
      ].join('\n');
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters.map((c) => c.title), [
        '第一章 起风',
        '第二章 落雨',
        '第三章 转晴',
      ]);
    });

    test('末尾空章被丢弃', () {
      final text = [
        '第一章 起风',
        '　　风从山口灌进来，吹得旗子啪啪作响，他一言不发。',
        '',
        '第二章 落雨',
        '　　雨点砸在瓦上，声音密得像有人在屋顶上跑。',
        '',
        '第三章',
        '　　',
        '',
      ].join('\n');
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.chapters.map((c) => c.title), ['第一章 起风', '第二章 落雨']);
    });

    test('空文件抛 BookParseException', () {
      expect(
        () => TxtParser().parse(Uint8List(0)),
        throwsA(isA<BookParseException>()),
      );
    });

    test('只有空白的文件抛 BookParseException', () {
      expect(
        () => TxtParser().parse(utf8Bytes('   \n\n　　\n')),
        throwsA(isA<BookParseException>()),
      );
    });
  });

  group('书名与自定义规则', () {
    test('文件名（去扩展名）优先作为书名', () {
      final book = TxtParser().parse(
        utf8Bytes(fiveChapterBook()),
        fileName: '剑来.txt',
      );
      expect(book.title, '剑来');
    });

    test('没有文件名时用正文首行当书名', () {
      final text = '测试之书\n第一章 起风\n　　${'风很大。' * 20}\n';
      final book = TxtParser().parse(utf8Bytes(text));
      expect(book.title, '测试之书');
    });

    test('自定义规则用 \$1/\$2 拼标题', () {
      final text = [
        '1 起风',
        '　　风从山口灌进来，吹得旗子啪啪作响，他一言不发。',
        '　　远处有人在喊他的名字。',
        '',
        '2 落雨',
        '　　雨点砸在瓦上，声音密得像有人在屋顶上跑。',
        '　　他把窗关上。',
      ].join('\n');
      final parser = TxtParser(
        tocRules: [r'^(\d+)\s+(.+)$' '\t' r'第$1章 $2'],
      );
      final book = parser.parse(utf8Bytes(text));
      expect(book.chapters.map((c) => c.title), ['第1章 起风', '第2章 落雨']);
    });

    test('非法正则被跳过而不是让整本书失败', () {
      final book = TxtParser(
        tocRules: ['([', r'^第.+章.*$'],
      ).parse(utf8Bytes(fiveChapterBook()));
      expect(book.chapters, hasLength(5));
    });
  });
}

/// 便捷读取元信息里的编码（避免测试里到处 `['charset']`）。
String? parseCharset(ParsedBook book) => book.metadata['charset'];
