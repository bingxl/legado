import 'dart:convert';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/service/source/source_group.dart';
import 'package:legado_core/src/service/source/source_io.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

import '../store/store_test_support.dart';

Map<String, Object?> sourceJson(
  String url, {
  String? name,
  String? group,
  int customOrder = 0,
  String searchUrl = '',
}) =>
    {
      'bookSourceUrl': url,
      'bookSourceName': name ?? '源$url',
      'bookSourceType': 0,
      'bookSourceGroup': group,
      'customOrder': customOrder,
      'enabled': true,
      'searchUrl': searchUrl,
      'ruleSearch': {'bookList': '.list'},
    };

/// 内联一份「23 个顶层字段」的超星结构书源：
/// 规则块每块 3–5 个子字段，用来守住 `fromJson → toJson` 不丢字段。
const Map<String, Object?> fullSourceJson = {
  'bookSourceUrl': 'https://chaoxing.example.com',
  'bookSourceName': '超星',
  'bookSourceGroup': '教育, 学术',
  'bookSourceType': 0,
  'bookUrlPattern': r'https://chaoxing\.example\.com/book/\d+',
  'customOrder': 12,
  'enabled': true,
  'enabledExplore': false,
  'jsLib': 'var helper = {};',
  'concurrentRate': '2/1000',
  'header': '{"User-Agent":"Mozilla/5.0"}',
  'loginUrl': 'https://chaoxing.example.com/login',
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
  'exploreUrl': '发现::https://chaoxing.example.com/discover',
  'exploreScreen': '[]',
  'searchUrl': 'https://chaoxing.example.com/search?q=',
};

void main() {
  late LegadoDatabase database;
  late StoreDaos daos;
  late SourceIoService io;
  late SourceGroupService groups;

  setUp(() {
    database = openTestDb();
    daos = StoreDaos(database.db);
    io = SourceIoService(daos);
    groups = SourceGroupService(daos);
  });

  tearDown(() => database.close());

  group('SourceIoService.importText', () {
    test('单个书源对象', () async {
      final result = await io.importText(jsonEncode(sourceJson('u1', name: '一号')));
      expect(result.imported, 1);
      expect(result.updated, 0);
      expect(result.failures, isEmpty);
      expect(result.sources, hasLength(1));
      expect(result.sources.single.url, 'u1');
      expect(result.sources.single.id, greaterThan(0));
      expect(daos.bookSource.getBookSource('u1')?.bookSourceName, '一号');
    });

    test('书源数组', () async {
      final result = await io.importText(jsonEncode([
        sourceJson('u1'),
        sourceJson('u2'),
      ]));
      expect(result.imported, 2);
      expect(result.sources.map((s) => s.url), ['u1', 'u2']);
      expect(daos.bookSource.allCount(), 2);
    });

    test('{"sources":[...]} 包裹', () async {
      final result = await io.importText(jsonEncode({
        'sources': [sourceJson('u1'), sourceJson('u2'), sourceJson('u3')],
      }));
      expect(result.imported, 3);
      expect(result.failures, isEmpty);
    });

    test('Legado 备份文件：只取 bookSource，忽略其它键', () async {
      final result = await io.importText(jsonEncode({
        'bookSource': [sourceJson('u1'), sourceJson('u2')],
        'bookSourceSub': [{'url': 'https://sub.example.com'}],
        'books': [{'name': '不应被导入'}],
      }));
      expect(result.imported, 2);
      expect(result.failures, isEmpty);
      expect(daos.bookSource.allCount(), 2);
      expect(daos.bookSource.getBookSource('u1'), isNotNull);
    });

    test('逐行 URL 只跳过，不报错', () async {
      final result = await io.importText('''
https://sub.example.com/a.json
https://sub.example.com/b.json
''');
      expect(result.imported, 0);
      expect(result.skipped, 2);
      expect(result.failures, isEmpty);
    });

    test('行模式里的非 URL 行进 failures', () async {
      final result = await io.importText('https://ok.example.com/a.json\n不是地址');
      expect(result.skipped, 1);
      expect(result.failures, hasLength(1));
      expect(result.failures.single.reason, contains('第 2 行'));
    });

    test('空文本给出明确错误', () async {
      final result = await io.importText('   \n  ');
      expect(result.imported, 0);
      expect(result.failures, isNotEmpty);
    });

    test('非法 JSON 给出解析错误而不是抛异常', () async {
      final result = await io.importText('{oops}');
      expect(result.imported, 0);
      expect(result.failures.single.reason, contains('JSON 解析失败'));
    });

    test('宽松 JSON：BOM + 尾部逗号 + // 注释，且 URL 里的 // 不被吞', () async {
      const text = '''
\uFEFF// 文件头注释
[
  {
    "bookSourceUrl": "https://a.example.com",
    "bookSourceName": "A", // 行尾注释
    "searchUrl": "https://a.example.com/search?q=",
    "ruleSearch": {"bookList": ".list",},
  },
]
''';
      final result = await io.importText(text);
      expect(result.failures, isEmpty);
      expect(result.imported, 1);
      final stored = daos.bookSource.getBookSource('https://a.example.com')!;
      expect(stored.searchUrl, 'https://a.example.com/search?q=');
      expect(stored.ruleSearch, '{"bookList":".list"}');
    });

    test('overwrite=false 时已存在跳过且不覆盖', () async {
      await io.importText(jsonEncode(sourceJson('u1', name: '旧名')));
      final result = await io.importText(jsonEncode(sourceJson('u1', name: '新名')));
      expect(result.imported, 0);
      expect(result.skipped, 1);
      expect(result.sources, isEmpty, reason: '跳过的书源不算成功导入');
      expect(daos.bookSource.getBookSource('u1')!.bookSourceName, '旧名');
    });

    test('overwrite=true 时走 update 并生效', () async {
      await io.importText(jsonEncode(sourceJson('u1', name: '旧名')));
      final result =
          await io.importText(jsonEncode(sourceJson('u1', name: '新名')), overwrite: true);
      expect(result.updated, 1);
      expect(result.imported, 0);
      expect(result.sources.single.name, '新名');
      expect(daos.bookSource.getBookSource('u1')!.bookSourceName, '新名');
    });

    test('overwrite=true 不能级联删掉搜索结果（必须 update 而非 REPLACE）', () async {
      await io.importText(jsonEncode(sourceJson('u1', name: '旧名')));
      daos.searchBook.insert(
        SearchBook(bookUrl: 'sb1', origin: 'u1', name: '书', author: '作者'),
      );

      await io.importText(jsonEncode(sourceJson('u1', name: '新名')), overwrite: true);

      expect(daos.searchBook.get('sb1'), isNotNull, reason: 'REPLACE 会先 DELETE 触发级联');
      expect(daos.bookSource.getBookSource('u1')!.bookSourceName, '新名');
    });

    test('失败项结构为 {name,url,reason}，其余条照常导入', () async {
      final result = await io.importText(jsonEncode([
        {'bookSourceName': '没有地址'},
        sourceJson('u2'),
      ]));
      expect(result.imported, 1);
      expect(result.failures, hasLength(1));
      final failure = result.failures.single;
      expect(failure.name, '没有地址');
      expect(failure.reason, contains('缺少 bookSourceUrl'));
      expect(failure.toJson().keys.toSet(), {'name', 'url', 'reason'});
    });

    test('raw 为 JSON 字符串且缺 bookSourceUrl 时用顶层 url 补全', () async {
      final result = await io.importText(jsonEncode({
        'url': 'https://fallback.example.com',
        'raw': jsonEncode({
          'bookSourceName': '包装源',
          'bookSourceType': 0,
        }),
      }));
      expect(result.failures, isEmpty);
      expect(result.imported, 1);
      expect(
        daos.bookSource.getBookSource('https://fallback.example.com')?.bookSourceName,
        '包装源',
      );
    });

    test('23 个顶层字段 fromJson → toJson 一个不丢', () async {
      final result = await io.importText(jsonEncode(fullSourceJson));
      expect(result.failures, isEmpty);
      expect(result.imported, 1);

      final stored = daos.bookSource.getBookSource('https://chaoxing.example.com')!;
      final exported = stored.toJson();

      expect(exported.keys.toSet(), containsAll(fullSourceJson.keys));
      expect(exported['bookSourceUrl'], fullSourceJson['bookSourceUrl']);
      expect(exported['ruleSearch'], isNull); // 这份样本没带 ruleSearch
      expect(exported['enabledExplore'], false);
      expect(exported['loginUi'], isA<List<Object?>>());
    });
  });

  group('SourceIoService.importBase64', () {
    test('契约入口：base64 解码后导入，结果结构一致', () async {
      final text = jsonEncode([sourceJson('u1'), sourceJson('u2')]);
      final encoded = base64Encode(utf8.encode(text));

      final result = await io.importBase64(encoded);
      expect(result.imported, 2);
      expect(result.toJson().keys.toSet(),
          {'imported', 'updated', 'skipped', 'sources', 'failures'});
      expect(daos.bookSource.allCount(), 2);
    });

    test('非法 base64 返回 failures 而不是抛异常', () async {
      final result = await io.importBase64('@@@不是base64@@@');
      expect(result.imported, 0);
      expect(result.failures.single.reason, contains('base64'));
    });
  });

  group('SourceIoService.exportJson / exportBase64', () {
    test('按 customOrder 升序输出', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', customOrder: 30),
        sourceJson('u2', customOrder: 10),
        sourceJson('u3', customOrder: 20),
      ]));
      final decoded = jsonDecode(await io.exportJson()) as List;
      expect(decoded.map((e) => (e as Map)['bookSourceUrl']), ['u2', 'u3', 'u1']);
    });

    test('按 ids 过滤；空 ids 等于全部', () async {
      final imported = await io.importText(jsonEncode([
        sourceJson('u1', customOrder: 1),
        sourceJson('u2', customOrder: 2),
        sourceJson('u3', customOrder: 3),
      ]));
      final secondId = imported.sources.firstWhere((s) => s.url == 'u2').id;

      final one = jsonDecode(await io.exportJson(ids: [secondId])) as List;
      expect(one.map((e) => (e as Map)['bookSourceUrl']), ['u2']);

      final all = jsonDecode(await io.exportJson(ids: const [])) as List;
      expect(all, hasLength(3));
    });

    test('exportBase64 返回可解码回 JSON 数组的 base64', () async {
      await io.importText(jsonEncode([sourceJson('u1'), sourceJson('u2')]));
      final encoded = await io.exportBase64(const []);
      final decoded = jsonDecode(utf8.decode(base64Decode(encoded))) as List;
      expect(decoded, hasLength(2));
      expect((decoded.first as Map)['bookSourceUrl'], 'u1');
    });

    test('导出再导入可完整还原', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', name: '一', group: '甲,乙', customOrder: 1),
        sourceJson('u2', name: '二', customOrder: 2),
      ]));
      final exported = await io.exportJson();

      final another = openTestDb();
      addTearDown(another.close);
      final anotherIo = SourceIoService(StoreDaos(another.db));
      final result = await anotherIo.importText(exported);

      expect(result.imported, 2);
      final restored = StoreDaos(another.db).bookSource.getBookSource('u1')!;
      expect(restored.bookSourceName, '一');
      expect(restored.bookSourceGroup, '甲,乙');
    });
  });

  group('SourceGroupService', () {
    test('listGroups 拆分中英文逗号、去空格、去重排序并带数量', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', group: '玄幻, 科幻'),
        sourceJson('u2', group: '玄幻，都市'),
        sourceJson('u3', group: '科幻;都市'),
      ]));

      final views = groups.listGroups();
      expect(views.map((v) => v.name), ['玄幻', '科幻', '都市']);
      expect(views.map((v) => v.count), [2, 2, 2]);
      expect(views.first.toJson(), {'name': '玄幻', 'count': 2});
    });

    test('listGroups 单分组计数正确', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', group: '玄幻'),
        sourceJson('u2', group: '玄幻,科幻'),
        sourceJson('u3'),
      ]));
      final views = groups.listGroups();
      expect(views.map((v) => (v.name, v.count)), [('玄幻', 2), ('科幻', 1)]);
    });

    test('rename 只改命中分组，其余原样保留并返回条数', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', group: '玄幻,科幻'),
        sourceJson('u2', group: '玄幻'),
        sourceJson('u3', group: '都市'),
      ]));

      final affected = await groups.rename('玄幻', '奇幻');
      expect(affected, 2);
      expect(daos.bookSource.getBookSource('u1')!.bookSourceGroup, '奇幻,科幻');
      expect(daos.bookSource.getBookSource('u2')!.bookSourceGroup, '奇幻');
      expect(daos.bookSource.getBookSource('u3')!.bookSourceGroup, '都市');
    });

    test('rename 到空字符串等价于删除该分组', () async {
      await io.importText(jsonEncode(sourceJson('u1', group: '玄幻,科幻')));
      await groups.rename('玄幻', '  ');
      expect(daos.bookSource.getBookSource('u1')!.bookSourceGroup, '科幻');
    });

    test('remove 从多值分组里摘掉一个，不影响其他分组', () async {
      await io.importText(jsonEncode([
        sourceJson('u1', group: '玄幻,科幻,都市'),
        sourceJson('u2', group: '科幻'),
      ]));

      final affected = await groups.remove('科幻');
      expect(affected, 2);
      expect(daos.bookSource.getBookSource('u1')!.bookSourceGroup, '玄幻,都市');
      expect(daos.bookSource.getBookSource('u2')!.bookSourceGroup, '');
    });

    test('重命名不存在的分组返回 0 且不写库', () async {
      await io.importText(jsonEncode(sourceJson('u1', group: '玄幻')));
      expect(await groups.rename('不存在', '新'), 0);
      expect(await groups.remove('不存在'), 0);
      expect(daos.bookSource.getBookSource('u1')!.bookSourceGroup, '玄幻');
    });
  });
}
