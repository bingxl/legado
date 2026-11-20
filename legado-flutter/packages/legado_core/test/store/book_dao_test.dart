import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/dao.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;
  late BookDao dao;

  setUp(() {
    database = openTestDb();
    dao = BookDao(database.db);
  });

  tearDown(() => database.close());

  Book book(String url, {String name = '书', String author = '作者', int group = 0}) =>
      Book(bookUrl: url, name: name, author: author, group: group, type: BookType.text);

  group('BookDao', () {
    test('插入后可按 Url / 书名作者 / 精确条件取回', () {
      dao.insert(book('b1'));
      expect(dao.getBook('b1')?.bookUrl, 'b1');
      expect(dao.getBookByNameAuthor('书', '作者')?.bookUrl, 'b1');
      expect(dao.has('b1'), isTrue);
      expect(dao.has('nope'), isFalse);
      expect(dao.hasBook('书', '作者'), isTrue);
      expect(dao.allBookCount, 1);
      expect(dao.allBookUrls, ['b1']);
    });

    test('重复插入同一主键是 REPLACE 而非报错', () {
      dao.insert(book('b1', name: '旧名'));
      dao.insert(book('b1', name: '新名'));
      expect(dao.allBookCount, 1);
      expect(dao.getBook('b1')!.name, '新名');
    });

    test('update 全字段生效，且不改变主键', () {
      dao.insert(book('b1'));
      dao.update(book('b1', name: '改名', author: '新作者', group: 2)
          .copyWith(durChapterIndex: 5, canUpdate: false));
      final stored = dao.getBook('b1')!;
      expect(stored.name, '改名');
      expect(stored.durChapterIndex, 5);
      expect(stored.canUpdate, isFalse);
      expect(stored.group, 2);
    });

    test('delete 按主键删除', () {
      dao.insert(book('b1'));
      dao.insert(book('b2', name: '书2'));
      dao.delete(book('b1'));
      expect(dao.getBook('b1'), isNull);
      expect(dao.allBookCount, 1);
    });

    test('getBooksByGroup 命中位域', () {
      dao.insert(book('b1', group: 1));
      dao.insert(book('b2', name: '书2', group: 2));
      dao.insert(book('b3', name: '书3', group: 1 + 2));
      final group1 = dao.getBooksByGroup(1).map((b) => b.bookUrl).toSet();
      expect(group1, {'b1', 'b3'});
      expect(dao.getBooksByGroup(4), isEmpty);
    });

    test('findByName 批量查询', () {
      dao.insert(book('b1', name: '甲', author: 'a1'));
      dao.insert(book('b2', name: '乙', author: 'a2'));
      final found = dao.findByName(['甲', '丙']);
      expect(found.map((b) => b.bookUrl), ['b1']);
      expect(dao.findByName(const []), isEmpty);
    });

    test('search 同时匹配书名与作者', () {
      dao.insert(book('b1', name: '斗破', author: '天蚕'));
      dao.insert(book('b2', name: '其他', author: '土豆'));
      expect(dao.search('斗').map((b) => b.bookUrl), ['b1']);
      expect(dao.search('土豆').map((b) => b.bookUrl), ['b2']);
    });

    test('insertAll 批量插入在一个事务内完成', () {
      dao.insertAll([for (var i = 0; i < 50; i++) book('b$i', name: '书$i')]);
      expect(dao.allBookCount, 50);
    });

    test('upProgress / upGroup / removeGroup', () {
      dao.insert(book('b1', group: 3));
      dao.upProgress('b1', 88);
      expect(dao.getBook('b1')!.durChapterPos, 88);

      dao.upGroup(3, 8);
      expect(dao.getBook('b1')!.group, 8);

      dao.insert(book('b2', name: '书2', group: 8 + 1));
      dao.removeGroup(8);
      expect(dao.getBook('b1')!.group, 0);
      expect(dao.getBook('b2')!.group, 1);
    });

    test('deleteNotShelfBooks 只删临时书', () {
      dao.insert(book('b1'));
      dao.insert(book('tmp', name: '临时书')
          .copyWith(type: BookType.text | BookType.notShelf));
      dao.deleteNotShelfBooks();
      expect(dao.allBookUrls, ['b1']);
    });

    test('getAllUseBookSource 排除本地书籍', () {
      final sourceDao = BookSourceDao(database.db);
      sourceDao.insert(BookSource(bookSourceUrl: 's1', bookSourceName: '源'));
      dao.insert(book('b1').copyWith(origin: 's1'));
      dao.insert(book('b2', name: '本地').copyWith(origin: BookType.localTag));
      final sources = dao.getAllUseBookSource();
      expect(sources.map((s) => s.bookSourceUrl), ['s1']);
    });
  });
}
