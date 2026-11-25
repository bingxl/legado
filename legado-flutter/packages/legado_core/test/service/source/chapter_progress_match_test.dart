import 'package:legado_core/src/service/source/chapter_progress_match.dart';
import 'package:test/test.dart';

/// 换源进度迁移：对齐 Kotlin `BookHelp.getDurChapter / getChapterNum /
/// getPureChapterName`。这些函数一旦算错，用户换源后打开的就是错章。
void main() {
  group('chapterNumOf', () {
    test('中文/阿拉伯数字、全角、各种分隔符', () {
      expect(chapterNumOf('第1章 开端'), 1);
      expect(chapterNumOf('第１２章 全角数字'), 12);
      expect(chapterNumOf('第一百二十三章 大结局'), 123);
      expect(chapterNumOf('第十二话'), 12);
      expect(chapterNumOf('12. 标题'), 12);
      expect(chapterNumOf('12、标题'), 12);
      // 千分位不认：原版 getChapterNum 同样在第一个「,」处截断（返回 1），
      // 不做数字清洗，这里保持一致。
      expect(chapterNumOf('1,000 章'), 1);
    });

    test('认不出序号返回 -1（序章/番外）', () {
      expect(chapterNumOf('序章'), -1);
      expect(chapterNumOf('番外 其一'), -1);
      expect(chapterNumOf(''), -1);
      expect(chapterNumOf(null), -1);
    });
  });

  group('pureChapterName', () {
    test('去掉序号、空白、括号，但不会清空整章名', () {
      expect(pureChapterName('第1章 开端'), '开端');
      expect(pureChapterName('第1章'), '第1章');
      expect(pureChapterName('【第一卷】觉醒'), '觉醒');
      // 数字后面必须有分隔符才算「序号」，否则当章名的一部分（原版同）。
      expect(pureChapterName('12、开始'), '开始');
      expect(pureChapterName('12 开始'), '12开始');
    });
  });

  group('jaccardSimilarity', () {
    test('完全一致为 1，无交集为 0', () {
      expect(jaccardSimilarity('开端', '开端'), 1);
      expect(jaccardSimilarity('开端', '终章'), 0);
      // 字符集合的 Jaccard：交集 1（开） / 并集 3（开 端 章）
      expect(jaccardSimilarity('开端', '开章'), closeTo(1 / 3, 1e-9));
      expect(jaccardSimilarity('', ''), 1);
    });
  });

  group('migrateChapterIndex', () {
    test('新源前面多了两章：同名章节仍能定位', () {
      final titles = ['序章', '楔子', '第1章 开端', '第2章 出发', '第3章 抵达'];
      final index = migrateChapterIndex(
        oldIndex: 1,
        oldTitle: '第1章 开端',
        newChapterTitles: titles,
        oldChapterListSize: 3,
      );
      expect(titles[index], '第1章 开端');
    });

    test('章名改了但章节号不变：按章节号命中', () {
      final titles = ['第1章 新的标题', '第2章 新的标题', '第3章 新的标题'];
      final index = migrateChapterIndex(
        oldIndex: 2,
        oldTitle: '第3章 旧标题',
        newChapterTitles: titles,
        oldChapterListSize: 3,
      );
      expect(index, 2);
    });

    test('既无同名也认不出章节号：回落到原序号（不越界）', () {
      final titles = ['甲', '乙', '丙'];
      final index = migrateChapterIndex(
        oldIndex: 2,
        oldTitle: '第99章 找不到',
        newChapterTitles: titles,
        oldChapterListSize: 3,
      );
      expect(index, 2);

      final clamped = migrateChapterIndex(
        oldIndex: 99,
        oldTitle: '第99章 找不到',
        newChapterTitles: titles,
        oldChapterListSize: 100,
      );
      expect(clamped, inInclusiveRange(0, 2));
    });

    test('首章直接返回 0', () {
      expect(
        migrateChapterIndex(
          oldIndex: 0,
          oldTitle: '第1章',
          newChapterTitles: ['第1章', '第2章'],
        ),
        0,
      );
    });
  });
}
