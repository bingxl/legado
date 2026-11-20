import 'dart:convert';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/dao/dao.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase database;
  late BookSourceDao dao;

  setUp(() {
    database = openTestDb();
    dao = BookSourceDao(database.db);
  });

  tearDown(() => database.close());

  BookSource source(String url, {String? group}) => BookSource(
        bookSourceUrl: url,
        bookSourceName: '源$url',
        bookSourceGroup: group,
        searchUrl: 'https://$url/search',
      );

  group('BookSourceDao', () {
    test('插入 / 按 Url 取回 / 计数 / has', () {
      dao.insert(source('a'));
      expect(dao.getBookSource('a')?.bookSourceName, '源a');
      expect(dao.getBookSource('nope'), isNull);
      expect(dao.allCount(), 1);
      expect(dao.has('a'), isTrue);
      expect(dao.has('b'), isFalse);
    });

    test('视图 book_sources_part 现算 hasLoginUrl / hasExploreUrl', () {
      dao.insert(source('a').copyWith(exploreUrl: '发现::https://a'));
      var part = dao.getBookSourcePart('a')!;
      expect(part.hasLoginUrl, isFalse);
      expect(part.hasExploreUrl, isTrue);

      final updated = dao.getBookSource('a')!.copyWith(loginUrl: 'https://a/login');
      dao.update(updated);
      part = dao.getBookSourcePart('a')!;
      expect(part.hasLoginUrl, isTrue);
      // 改为空串应重新变回 false（trim 后为空）。
      dao.update(dao.getBookSource('a')!.copyWith(loginUrl: '   '));
      expect(dao.getBookSourcePart('a')!.hasLoginUrl, isFalse);
    });

    test('patchRaw：JSON 合并进实体、规则重新序列化、标量收类型', () {
      dao.insert(source('a'));
      final editing = dao.getBookSource('a')!;
      editing.patchRaw({
        'bookSourceName': '改名',
        'enabled': 0,
        'customOrder': '12',
        'ruleSearch': {'bookList': '.book'},
        'ruleToc': '{"chapterList":".ch"}',
        'unknownLegacyKey': '忽略',
      });
      dao.update(editing);

      final stored = dao.getBookSource('a')!;
      expect(stored.bookSourceName, '改名');
      expect(stored.enabled, isFalse);
      expect(stored.customOrder, 12);
      expect(jsonDecode(stored.ruleSearch!), {'bookList': '.book'});
      expect(stored.ruleToc, '{"chapterList":".ch"}');
      expect(stored.toRow().containsKey('unknownLegacyKey'), isFalse);
    });

    test('fromJson / toJson 保持书源 JSON 结构', () {
      final json = {
        'bookSourceUrl': 'u1',
        'bookSourceName': 'JSON源',
        'enabled': false,
        'bookSourceType': 1,
        'ruleSearch': {'bookList': '.list', 'name': '.name'},
        'ruleExplore': null,
        'loginUi': [
          {'name': '用户名', 'type': 'text'},
        ],
      };
      final parsed = BookSource.fromJson(json);
      expect(parsed.enabled, isFalse);
      expect(parsed.bookSourceType, 1);
      expect(jsonDecode(parsed.ruleSearch!), isA<Map<String, Object?>>());
      expect(jsonDecode(parsed.loginUi!), isA<List<Object?>>());

      final back = parsed.toJson();
      expect(back['bookSourceUrl'], 'u1');
      expect(back['enabled'], isFalse);
      expect(back['ruleSearch'], {'bookList': '.list', 'name': '.name'});
    });

    test('23 个顶层字段 fromJson → toJson 零丢失', () {
      // 结构取自真实「超星书源」样本，内联而不是读文件：
      // 这条用例的职责是拦住「以后加了字段忘了改 toJson」。
      const json = <String, Object?>{
        'bookSourceUrl': 'https://cx.example.com',
        'bookSourceName': '超星',
        'bookSourceGroup': '教育, 学术',
        'bookSourceType': 0,
        'bookUrlPattern': r'https://cx\.example\.com/book/\d+',
        'customOrder': 12,
        'enabled': true,
        'enabledExplore': false,
        'jsLib': 'var helper = {};',
        'concurrentRate': '2/1000',
        'header': '{"User-Agent":"Mozilla/5.0"}',
        'loginUrl': 'https://cx.example.com/login',
        'loginUi': [
          {'name': '账号', 'type': 'text'},
          {'name': '密码', 'type': 'password'},
        ],
        'loginCheckJs': 'result.login === true',
        'coverDecodeJs': 'return url;',
        'bookSourceComment': '仅供测试',
        'variableComment': '登录后可用',
        'lastUpdateTime': 1700000000000,
        'respondTime': 321,
        'weight': 5,
        'exploreUrl': '发现::https://cx.example.com/discover',
        'exploreScreen': '[]',
        'searchUrl': 'https://cx.example.com/search?q=',
      };

      final parsed = BookSource.fromJson(json);
      final back = parsed.toJson();

      expect(back.keys.toSet(), containsAll(json.keys));
      expect(back['bookSourceUrl'], json['bookSourceUrl']);
      expect(back['bookSourceGroup'], '教育, 学术');
      expect(back['enabledExplore'], isFalse);
      expect(back['loginUi'], isA<List<Object?>>());
      expect((back['loginUi'] as List).length, 2);
      expect(back['weight'], 5);

      // 落库后再走一遍，确认 JSON 列的存取没有丢层级。
      dao.insert(parsed);
      final stored = dao.getBookSource('https://cx.example.com')!;
      expect(stored.toJson().keys.toSet(), containsAll(json.keys));
      expect(jsonDecode(stored.loginUi!), isA<List<Object?>>());
    });

    test('分组：精确匹配与模糊包含', () {
      dao.insert(source('a', group: '玄幻,都市'));
      dao.insert(source('b', group: '玄幻'));
      dao.insert(source('c', group: '科幻'));
      expect(dao.groupSearch('玄幻').map((s) => s.bookSourceUrl).toSet(), {'a', 'b'});
      expect(dao.getByGroup('都市').map((s) => s.bookSourceUrl), ['a']);
    });

    test('分组名拆分去重排序', () {
      dao.insert(source('a', group: '都市,玄幻'));
      dao.insert(source('b', group: '玄幻;科幻'));
      expect(dao.allGroups(), ['玄幻', '科幻', '都市']);
      expect(dao.allGroupsUnprocessed.length, 2);
    });

    test('enable / enableExplore / upOrder / upGroup', () {
      dao.insert(source('a'));
      dao.enable('a', false);
      dao.enableExplore('a', false);
      dao.upOrder('a', 30);
      dao.upGroup('a', '新分组');
      final stored = dao.getBookSource('a')!;
      expect(stored.enabled, isFalse);
      expect(stored.enabledExplore, isFalse);
      expect(stored.customOrder, 30);
      expect(stored.bookSourceGroup, '新分组');
      expect(dao.allDisabled.map((s) => s.bookSourceUrl), ['a']);
    });

    test('按类型与启用状态过滤', () {
      // getEnabledByType 要求 bookUrlPattern 非 'NONE'（NULL != 'NONE' 为 NULL，不会命中），
      // 与 Kotlin 原 SQL 一致，所以这里显式给一个正则。
      dao.insert(source('a')
          .copyWith(bookSourceType: BookSourceType.text, bookUrlPattern: '.*'));
      dao.insert(source('b')
          .copyWith(bookSourceType: BookSourceType.audio, bookUrlPattern: '.*'));
      expect(dao.getEnabledByType(BookSourceType.audio).map((s) => s.bookSourceUrl), ['b']);
      expect(dao.allEnabledPart.length, 2);
    });

    test('删除书源会级联删除搜索结果', () {
      dao.insert(source('a'));
      final searchDao = SearchBookDao(database.db);
      searchDao.insert(SearchBook(bookUrl: 'sb', origin: 'a', name: '书', author: '作者'));
      dao.deleteByKey('a');
      expect(searchDao.get('sb'), isNull);
    });

    test('deleteAllByKey 在一个事务里删多条', () {
      dao.insertAll([source('a'), source('b'), source('c')]);
      dao.deleteAllByKey(['a', 'c']);
      expect(dao.all.map((s) => s.bookSourceUrl), ['b']);
    });
  });
}
