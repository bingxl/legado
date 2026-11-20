import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/dao.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;

  setUp(() {
    database = openTestDb();
    BookDao(database.db).insert(Book(bookUrl: 'b1', name: '书', author: '作者'));
  });

  tearDown(() => database.close());

  group('事务', () {
    test('runInTransaction：异常时整体回滚', () {
      final bookDao = BookDao(database.db);
      expect(
        () => runInTransaction(database.db, () {
          bookDao.insert(Book(bookUrl: 'b2', name: '书2', author: '作者'));
          throw StateError('中途失败');
        }),
        throwsA(isA<StateError>()),
      );
      expect(bookDao.getBook('b2'), isNull);
      expect(bookDao.allBookCount, 1);
    });

    test('runInTransaction：成功时一次提交，返回结果', () {
      final bookDao = BookDao(database.db);
      final count = runInTransaction(database.db, () {
        bookDao.insert(Book(bookUrl: 'b2', name: '书2', author: '作者'));
        bookDao.insert(Book(bookUrl: 'b3', name: '书3', author: '作者'));
        return bookDao.allBookCount;
      });
      expect(count, 3);
    });

    test('章节批量插入中途外键失败：已插入的章节也不留下', () {
      final chapterDao = BookChapterDao(database.db);
      expect(
        () => chapterDao.insertAll([
          BookChapter(url: 'c0', title: '第0章', bookUrl: 'b1', index: 0),
          BookChapter(url: 'c1', title: '第1章', bookUrl: 'b1', index: 1),
          // bookUrl 指向不存在的书，触发外键约束。
          BookChapter(url: 'cx', title: '孤儿章', bookUrl: 'missing', index: 0),
        ]),
        throwsA(isA<SqliteException>()),
      );
      expect(chapterDao.getChapterCount('b1'), 0);
    });

    test('书源批量插入中途失败：不留下半批数据', () {
      final sourceDao = BookSourceDao(database.db);
      expect(
        () => sourceDao.insertAll([
          BookSource(bookSourceUrl: 's1', bookSourceName: '一'),
          BookSource(bookSourceUrl: 's2', bookSourceName: '二'),
          BookSource(bookSourceUrl: 's3', bookSourceName: '三'),
        ]),
        returnsNormally,
      );
      expect(sourceDao.allCount(), 3);
    });
  });
}
