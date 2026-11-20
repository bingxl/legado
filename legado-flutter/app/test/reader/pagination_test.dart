import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/pagination.dart';

/// 分页是纯函数，直接在普通 test 里跑，不依赖网络、不依赖 core。
/// 测试字体是等宽的 Ahem，每个字符占一个 fontSize 方块，行高由 `height` 决定，
/// 所以「宽 320 / 字 16 → 每行 20 字」这类推导是稳定的。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const typography = ReaderTypography(
    fontSize: 16,
    lineHeight: 1.5,
    paragraphSpacing: 8,
    indent: '　　',
  );

  /// 每页 4 行左右的小版心，方便构造多页场景。
  const smallPage = Size(320, 96);

  group('paginate', () {
    test('长段落被切成多页且不丢字', () {
      final text = '山间的风穿过松林，带来潮湿的凉意。' * 100;
      final pages = paginate(
        paragraphs: [text],
        pageSize: smallPage,
        typography: typography,
      );

      expect(pages.length, greaterThan(1));
      for (final page in pages) {
        expect(page.blocks, isNotEmpty, reason: '第 ${page.index} 页不应该为空');
      }

      final joined = pages.expand((p) => p.blocks).map((b) => b.text).join();
      expect(joined, '${typography.indent}$text');
    });

    test('空行保留为独立文本块', () {
      final pages = paginate(
        paragraphs: ['第一段', '', '第三段'],
        pageSize: const Size(320, 480),
        typography: typography,
      );
      final blocks = pages.expand((p) => p.blocks).toList();
      expect(blocks.where((b) => b.text.isEmpty), isNotEmpty);
      expect(
        blocks.map((b) => b.text).toList(),
        containsAll(<String>[
          '${typography.indent}第一段',
          '${typography.indent}第三段',
        ]),
      );
      // 空段落自己就是段末，渲染时会少一个段间距。
      final blank = blocks.firstWhere((b) => b.text.isEmpty);
      expect(blank.endsParagraph, isTrue);
    });

    test('超长单句（无标点）也能分页且不死循环', () {
      final text = '一' * 5000;
      final pages = paginate(
        paragraphs: [text],
        pageSize: const Size(320, 200),
        typography: typography,
      );

      expect(pages.length, greaterThan(1));
      final joined = pages.expand((p) => p.blocks).map((b) => b.text).join();
      expect(joined.length, typography.indent.length + 5000);
      expect(joined, '${typography.indent}$text');
    });

    test('版心比行高还小时每页至少放一行', () {
      final pages = paginate(
        paragraphs: ['一二三四五六七八九十'],
        pageSize: const Size(80, 10),
        typography: typography,
      );
      expect(pages, isNotEmpty);
      expect(pages.every((p) => p.blocks.isNotEmpty), isTrue);
      // 每行只放得下一个字（宽 80 / 字 16 = 4 字，但高只有 10）。
      expect(pages.length, greaterThan(1));
    });

    test('空段落列表返回单张空页', () {
      final pages = paginate(
        paragraphs: const [],
        pageSize: smallPage,
        typography: typography,
      );
      expect(pages, hasLength(1));
      expect(pages.single.blocks, isEmpty);
      expect(pages.single.startOffset, 0);
    });

    test('起点偏移随页码单调递增，可用于恢复进度', () {
      final pages = paginate(
        paragraphs: List<String>.generate(20, (i) => '第$i段：${'正文内容' * 10}'),
        pageSize: smallPage,
        typography: typography,
      );
      expect(pages.length, greaterThan(2));
      var previous = -1;
      for (final page in pages) {
        expect(page.startOffset, greaterThan(previous));
        previous = page.startOffset;
      }
    });

    test('段间距会占用版面，页数不小于无间距时', () {
      final paragraphs = List<String>.generate(30, (i) => '段落$i：${'字' * 40}');
      final tight = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(320, 200),
        typography: typography.copyWith(paragraphSpacing: 0),
      );
      final loose = paginate(
        paragraphs: paragraphs,
        pageSize: const Size(320, 200),
        typography: typography.copyWith(paragraphSpacing: 24),
      );
      expect(loose.length, greaterThanOrEqualTo(tight.length));
    });

    test('缩进参与测量，首行确实带缩进', () {
      final custom = typography.copyWith(indent: '>>');
      final pages = paginate(
        paragraphs: ['缩进测试'],
        pageSize: const Size(320, 480),
        typography: custom,
      );
      expect(pages.single.blocks.single.text, '>>缩进测试');
    });
  });

  group('页码换算', () {
    late List<PageSlice> pages;

    setUp(() {
      pages = paginate(
        paragraphs: List<String>.generate(12, (i) => '第$i段 ${'测试内容' * 12}'),
        pageSize: smallPage,
        typography: typography,
      );
    });

    test('按偏移查找页：每页起点都能定位回自己', () {
      for (var i = 0; i < pages.length; i++) {
        expect(pageIndexForOffset(pages, pages[i].startOffset), i);
      }
      expect(pageIndexForOffset(pages, -5), 0);
      expect(pageIndexForOffset(pages, 1 << 30), pages.length - 1);
    });

    test('百分比与页码互为反函数', () {
      for (var i = 0; i < pages.length; i++) {
        final percent = percentForPageIndex(pages, i);
        expect(percent, inInclusiveRange(0, 1));
        expect(pageIndexForPercent(pages, percent), i);
      }
      expect(pageIndexForPercent(pages, 0), 0);
      expect(pageIndexForPercent(pages, 1), pages.length - 1);
      expect(percentForPageIndex(const [], 3), 0);
      expect(pageIndexForPercent(const [], 0.5), 0);
    });

    test('页内的偏移定位到当前页而不是上一页', () {
      final page = pages[1];
      final inside = page.startOffset + 1;
      expect(pageIndexForOffset(pages, inside), 1);
    });
  });

  group('paginate 内联图片', () {
    test('图片按给定高度占据独立块，且文字仍在原位置', () {
      const imageUrl = 'https://img.test/a.jpg';
      final pages = paginate(
        paragraphs: ['前文', '', '后文'],
        pageSize: const Size(320, 600),
        typography: typography,
        imageUrls: {1: imageUrl},
      );
      final blocks = pages.single.blocks;
      expect(blocks.length, 3);
      expect(blocks[0].text, contains('前文'));
      expect(blocks[1].isImage, isTrue);
      expect(blocks[1].imageUrl, imageUrl);
      expect(blocks[1].imageHeight, typography.imageBlockHeight(600));
      expect(blocks[2].text, contains('后文'));
    });

    test('图片高度受版心限制，不会把整页文字挤掉', () {
      final height = typography.imageBlockHeight(100);
      expect(height, lessThanOrEqualTo(60));
      expect(height, greaterThanOrEqualTo(48));
    });
  });
}
