import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/dao.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;

  setUp(() => database = openTestDb());
  tearDown(() => database.close());

  group('CacheDao', () {
    test('永不过期的值可以取出', () {
      final dao = CacheDao(database.db);
      dao.put('k', 'v');
      expect(dao.get('k')?.value, 'v');
      expect(dao.getValid('k', 9999999999999), 'v');
    });

    test('过期的值查得到但不参与 getValid', () {
      final dao = CacheDao(database.db);
      dao.put('k', 'v', deadline: 100);
      expect(dao.getValid('k', 99), 'v');
      expect(dao.getValid('k', 101), isNull);
      expect(dao.get('k')?.value, 'v');
    });

    test('deleteSourceVariables 只清该源的变量与登录缓存', () {
      final dao = CacheDao(database.db);
      final keys = [
        'v_s1_key',
        'userInfo_s1',
        'loginHeader_s1',
        'sourceVariable_s1',
        'v_s2_key',
        'other',
      ];
      for (final key in keys) {
        dao.put(key, 'x');
      }
      dao.deleteSourceVariables('s1');
      expect(
        keys.where((k) => dao.get(k) != null),
        ['v_s2_key', 'other'],
      );
    });

    test('clearDeadline 清理已过期行', () {
      final dao = CacheDao(database.db);
      dao.put('old', 'x', deadline: 10);
      dao.put('forever', 'y');
      dao.clearDeadline(100);
      expect(dao.get('old'), isNull);
      expect(dao.get('forever')?.value, 'y');
    });
  });

  group('ReplaceRuleDao', () {
    test('id 为 0 时自动补一个非零 id', () {
      final dao = ReplaceRuleDao(database.db);
      dao.insert(ReplaceRule(name: '规则', pattern: 'a'));
      expect(dao.all.single.id, isNot(0));
    });

    test('正文/标题作用域分别筛选，排除范围生效', () {
      final dao = ReplaceRuleDao(database.db);
      dao.insert(ReplaceRule(id: 1, name: '正文', pattern: 'a', scopeContent: true));
      dao.insert(ReplaceRule(
        id: 2,
        name: '标题',
        pattern: 'b',
        scopeTitle: true,
        scopeContent: false,
      ));
      dao.insert(ReplaceRule(
        id: 3,
        name: '排除',
        pattern: 'c',
        scopeContent: true,
        excludeScope: '某书',
      ));
      expect(
        dao.findEnabledByContentScope('某书', 'https://a').map((r) => r.id),
        [1],
      );
      expect(dao.findEnabledByTitleScope('某书', 'https://a').map((r) => r.id), [2]);
    });

    test('enableAll 批量启停，disabledCount 正确', () {
      final dao = ReplaceRuleDao(database.db);
      dao.insert(ReplaceRule(id: 1, name: 'a', pattern: 'a'));
      dao.insert(ReplaceRule(id: 2, name: 'b', pattern: 'b'));
      expect(dao.disabledCount, 0);
      dao.enableAll(false);
      expect(dao.disabledCount, 2);
      expect(dao.allEnabled, isEmpty);
    });
  });

  group('ReadRecordDao', () {
    test('allShow 按书聚合多设备时长', () {
      final dao = ReadRecordDao(database.db);
      dao.insert(ReadRecord(deviceId: 'd1', bookName: '书', readTime: 10, lastRead: 100));
      dao.insert(ReadRecord(deviceId: 'd2', bookName: '书', readTime: 20, lastRead: 200));
      dao.insert(ReadRecord(deviceId: 'd1', bookName: '另一本', readTime: 5, lastRead: 50));

      final show = dao.allShow;
      expect(show.length, 2);
      final book = show.firstWhere((s) => s.bookName == '书');
      expect(book.readTime, 30);
      expect(book.lastRead, 200);
      expect(dao.allTime, 35);
    });

    test('按设备 + 书名取时长，缺省返回 null', () {
      final dao = ReadRecordDao(database.db);
      dao.insert(ReadRecord(deviceId: 'd1', bookName: '书', readTime: 7));
      expect(dao.getReadTime('d1', '书'), 7);
      expect(dao.getReadTime('d2', '书'), isNull);
      expect(dao.getReadTimeByBook('书'), 7);
    });
  });

  group('RssArticleDao', () {
    test('byOriginSort 左连已读记录', () {
      final dao = RssArticleDao(database.db);
      dao.insert(RssArticle(origin: 'o', sort: 's', title: '已读', order: 2, link: 'l1'));
      dao.insert(RssArticle(origin: 'o', sort: 's', title: '未读', order: 1, link: 'l2'));
      RssReadRecordDao(database.db)
          .insertRecord(RssReadRecord(record: 'l1', read: true));

      final list = dao.byOriginSort('o', 's');
      expect(list.map((a) => a.link), ['l1', 'l2'], reason: '按 order 倒序');
      expect(list.firstWhere((a) => a.link == 'l1').read, isTrue);
      expect(list.firstWhere((a) => a.link == 'l2').read, isFalse);
    });

    test('append 遇到已存在 (origin, link) 时不覆盖', () {
      final dao = RssArticleDao(database.db);
      dao.insert(RssArticle(origin: 'o', sort: 's', title: '旧', link: 'l'));
      dao.append(RssArticle(origin: 'o', sort: 's', title: '新', link: 'l'));
      expect(dao.get('o', 'l')!.title, '旧');
    });

    test('clearOld 删除更旧的文章', () {
      final dao = RssArticleDao(database.db);
      dao.insert(RssArticle(origin: 'o', sort: 's', title: '旧', order: 1, link: 'l1'));
      dao.insert(RssArticle(origin: 'o', sort: 's', title: '新', order: 5, link: 'l2'));
      dao.clearOld('o', 's', 3);
      expect(dao.byOriginSort('o', 's').map((a) => a.link), ['l2']);
    });
  });

  group('其他 DAO', () {
    test('CookieDao：普通/OkHttp 两类分开清理', () {
      final dao = CookieDao(database.db);
      dao.insert(Cookie(url: 'https://a', cookie: 'a=1'));
      dao.insert(Cookie(url: 'https://a|path=/|', cookie: 'b=2'));
      expect(dao.get('https://a')?.cookie, 'a=1');
      expect(dao.getOkHttpCookies().map((c) => c.cookie), ['b=2']);
      dao.deleteOkHttp();
      expect(dao.get('https://a|path=/|'), isNull);
      expect(dao.getOkHttpCookies(), isEmpty);
    });

    test('SearchKeywordDao：按使用次数排序与替换', () {
      final dao = SearchKeywordDao(database.db);
      dao.insert(SearchKeyword(word: 'a', usage: 1, lastUseTime: 1));
      dao.insert(SearchKeyword(word: 'b', usage: 5, lastUseTime: 2));
      expect(dao.byUsage().map((k) => k.word), ['b', 'a']);
      expect(dao.byTime().map((k) => k.word), ['b', 'a']);
      dao.insert(SearchKeyword(word: 'a', usage: 9, lastUseTime: 3));
      expect(dao.byUsage().map((k) => k.word), ['a', 'b']);
    });

    test('SearchBookDao：清理过期与按书名作者清空', () {
      final sourceDao = BookSourceDao(database.db);
      sourceDao.insert(BookSource(bookSourceUrl: 's', bookSourceName: '源'));
      final dao = SearchBookDao(database.db);
      dao.insert(SearchBook(bookUrl: 's1', origin: 's', name: '书', author: 'a', time: 10));
      dao.insert(SearchBook(bookUrl: 's2', origin: 's', name: '书', author: 'a', time: 100));
      dao.clearExpired(50);
      expect(dao.get('s1'), isNull);
      expect(dao.get('s2'), isNotNull);
      dao.clear('书', 'a');
      expect(dao.get('s2'), isNull);
    });

    test('HttpTTSDao / ServerDao / TxtTocRuleDao 的内置项清理', () {
      final ttsDao = HttpTTSDao(database.db);
      ttsDao.insert(HttpTTS(id: -1, name: '内置', url: 'u'));
      ttsDao.insert(HttpTTS(id: 1, name: '用户', url: 'u'));
      ttsDao.deleteDefault();
      expect(ttsDao.all.map((t) => t.id), [1]);

      final serverDao = ServerDao(database.db);
      serverDao.insert(Server(id: -1, name: '内置'));
      serverDao.insert(Server(id: 2, name: '用户'));
      serverDao.deleteDefault();
      expect(serverDao.all.map((s) => s.id), [2]);

      final tocDao = TxtTocRuleDao(database.db);
      tocDao.insert(TxtTocRule(id: -1, name: '内置', rule: 'r'));
      tocDao.insert(TxtTocRule(id: 3, name: '用户', rule: 'r'));
      tocDao.deleteDefault();
      expect(tocDao.all.map((r) => r.id), [3]);
    });
  });
}
