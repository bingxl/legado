import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/dao.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;
  late BookDao bookDao;
  late BookChapterDao dao;

  setUp(() {
    database = openTestDb();
    bookDao = BookDao(database.db);
    dao = BookChapterDao(database.db);
    bookDao.insert(Book(bookUrl: 'b1', name: '书', author: '作者'));
  });

  tearDown(() => database.close());

  BookChapter chapter(int index, {String? title}) => BookChapter(
        url: 'c$index',
        title: title ?? '第$index章',
        bookUrl: 'b1',
        index: index,
      );

  group('BookChapterDao', () {
    test('批量插入后按 index 有序返回', () {
      dao.insertAll([for (var i = 9; i >= 0; i--) chapter(i)]);
      final list = dao.getChapterList('b1');
      expect(list.map((c) => c.index), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(dao.getChapterCount('b1'), 10);
    });

    test('getChapter 按 (bookUrl, index) 命中', () {
      dao.insertAll([chapter(0), chapter(1)]);
      expect(dao.getChapter('b1', 1)?.title, '第1章');
      expect(dao.getChapter('b1', 99), isNull);
      expect(dao.getChapter('b2', 0), isNull);
    });

    test('getChapterByTitle', () {
      dao.insertAll([chapter(0, title: '序章'), chapter(1)]);
      expect(dao.getChapterByTitle('b1', '序章')?.index, 0);
      expect(dao.getChapterByTitle('b1', '不存在'), isNull);
    });

    test('区间查询含首尾', () {
      dao.insertAll([for (var i = 0; i < 5; i++) chapter(i)]);
      expect(dao.getChapterListRange('b1', 1, 3).map((c) => c.index), [1, 2, 3]);
    });

    test('按标题搜索', () {
      dao.insertAll([chapter(0, title: '张三丰'), chapter(1, title: '李四')]);
      expect(dao.search('b1', '张三').map((c) => c.index), [0]);
      expect(dao.searchRange('b1', '四', 0, 5).map((c) => c.index), [1]);
    });

    test('更新章节字段', () {
      dao.insert(chapter(0));
      dao.update(chapter(0, title: '改名').copyWith(wordCount: '1000', isVip: true));
      final stored = dao.getChapter('b1', 0)!;
      expect(stored.title, '改名');
      expect(stored.wordCount, '1000');
      expect(stored.isVip, isTrue);
    });

    test('upWordCount 只改指定章节', () {
      dao.insertAll([chapter(0), chapter(1)]);
      dao.upWordCount('b1', 'c1', '2048');
      expect(dao.getChapter('b1', 1)!.wordCount, '2048');
      expect(dao.getChapter('b1', 0)!.wordCount, isNull);
    });

    test('deleteByBookUrl 只删本书章节', () {
      dao.insertAll([chapter(0), chapter(1)]);
      bookDao.insert(Book(bookUrl: 'b2', name: '书2', author: '作者2'));
      dao.insert(BookChapter(url: 'x', title: 'x', bookUrl: 'b2', index: 0));
      dao.deleteByBookUrl('b1');
      expect(dao.getChapterCount('b1'), 0);
      expect(dao.getChapterCount('b2'), 1);
    });

    test('批量插入为空时不做任何事', () {
      expect(() => dao.insertAll(const []), returnsNormally);
      expect(dao.getChapterCount('b1'), 0);
    });
  });
}
