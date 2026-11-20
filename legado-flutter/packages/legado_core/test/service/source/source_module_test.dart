import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/source/source_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 书源域本地管理接线测试：CRUD / 导入导出 / 分组 / 批量排序 / 变量 / 订阅。
void main() {
  late Directory home;
  late StoreModule store;
  late SourceModule module;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-source-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    module = SourceModule();
    module.register(registry, ctx());
  });

  tearDown(() async {
    await module.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(
    String method, [
    List<Object?> args = const [],
  ]) async => (await call(method, args) as List).cast<Map<String, Object?>>();

  Future<Map<String, Object?>> callMap(
    String method, [
    List<Object?> args = const [],
  ]) async => (await call(method, args) as Map).cast<String, Object?>();

  String rawOf(
    String url, {
    String name = '测试源',
    String group = '',
    bool explore = true,
  }) => jsonEncode(<String, Object?>{
    'bookSourceUrl': url,
    'bookSourceName': name,
    'bookSourceGroup': group,
    'enabled': true,
    'enabledExplore': explore,
    'customOrder': 0,
    'searchUrl': '$url/search?q={{key}}',
    'ruleSearch': '{"bookList":".item","name":".title"}',
    'ruleBookInfo': '{"author":".author"}',
    'ruleToc': '{"chapterList":".chapter"}',
    'ruleContent': '{"content":"#content"}',
  });

  Future<Map<String, Object?>> addSource(
    String url, {
    String name = '测试源',
    String group = '',
  }) => callMap('Source.Save', [
    0,
    name,
    group,
    url,
    '备注',
    rawOf(url, name: name, group: group),
    true,
    1,
  ]);

  test('依赖与全部本地管理方法已注册', () {
    expect(module.name, 'source');
    expect(module.dependsOn, contains('store'));
    final names = registry.all.map((m) => m.name).toList();
    expect(
      names,
      containsAll(<String>[
        'Source.List',
        'Source.Get',
        'Source.Save',
        'Source.Delete',
        'Source.SetEnabled',
        'Source.Import',
        'Source.ImportFromURL',
        'Source.Export',
        'Source.Validate',
        'Source.ListGroups',
        'Source.AddGroupToNoGroup',
        'Source.RenameGroup',
        'Source.DeleteGroup',
        'Source.AddToGroup',
        'Source.RemoveFromGroup',
        'Source.SetEnabledBatch',
        'Source.SetEnabledExploreBatch',
        'Source.DeleteBatch',
        'Source.MoveTop',
        'Source.MoveBottom',
        'Source.Reorder',
        'Source.GetVariable',
        'Source.SetVariable',
        'Source.ClearCookie',
        'Source.ListSubscriptions',
        'Source.GetSubscription',
        'Source.SaveSubscription',
        'Source.DeleteSubscription',
        'Source.SetSubscriptionEnabled',
        'Source.SyncSubscription',
        'Source.SyncAllSubscriptions',
      ]),
    );
  });

  test('Save/List/Get/Delete：列表无 raw，详情有 raw', () async {
    final view = await addSource('https://example.test/a');
    final id = view['id'] as int;
    expect(view['name'], '测试源');
    expect(view['url'], 'https://example.test/a');

    final list = await callList('Source.List', ['']);
    expect(list.length, 1);
    expect(list.single.containsKey('raw'), isTrue);
    expect(list.single['raw'], '');

    final detail = await callMap('Source.Get', [id]);
    expect(
      jsonDecode(detail['raw'] as String)['bookSourceUrl'],
      'https://example.test/a',
    );

    await call('Source.Delete', [id]);
    expect(await callList('Source.List', ['']), isEmpty);
    await expectLater(
      call('Source.Get', [id]),
      throwsA(
        isA<LegadoException>().having(
          (e) => e.code,
          'code',
          ErrorCode.notFound,
        ),
      ),
    );
  });

  test('Save 的 raw 缺 URL 时用 url 参数补全', () async {
    final raw = jsonEncode({'bookSourceName': '补全源', 'ruleSearch': '{}'});
    final view = await callMap('Source.Save', [
      0,
      '补全源',
      '',
      'https://example.test/fill',
      '',
      raw,
      true,
      0,
    ]);
    expect(view['url'], 'https://example.test/fill');
  });

  test('导入 / 导出：base64 往返，重复导入可跳过', () async {
    final payload = jsonEncode([jsonDecode(rawOf('https://example.test/imp'))]);
    final encoded = base64Encode(utf8.encode(payload));
    final result = await callMap('Source.Import', [encoded, false]);
    expect(result['imported'], 1);

    final again = await callMap('Source.Import', [encoded, false]);
    expect(again['skipped'], 1);

    final exported = await call('Source.Export', [const <int>[]]) as String;
    final items = jsonDecode(utf8.decode(base64Decode(exported))) as List;
    expect(items, hasLength(1));
    expect((items.first as Map)['bookSourceUrl'], 'https://example.test/imp');
  });

  test('分组：新增/改名/添加/移除/删除', () async {
    await addSource('https://example.test/g1');
    final first = (await callList('Source.List', [''])).first;
    final id = first['id'] as int;

    expect(await call('Source.AddGroupToNoGroup', ['小说']), 1);
    expect((await callList('Source.ListGroups')).single['name'], '小说');

    await call('Source.AddToGroup', [
      [id],
      '玄幻',
    ]);
    expect((await callMap('Source.Get', [id]))['group'], contains('玄幻'));

    await call('Source.RemoveFromGroup', [
      [id],
      '玄幻',
    ]);
    expect((await callMap('Source.Get', [id]))['group'], isNot(contains('玄幻')));

    await call('Source.RenameGroup', ['小说', '文学']);
    expect((await callList('Source.ListGroups')).single['name'], '文学');

    await call('Source.DeleteGroup', ['文学']);
    expect(await callList('Source.ListGroups'), isEmpty);
  });

  test('批量启停 / 排序 / 删除', () async {
    await addSource('https://example.test/b1');
    await addSource('https://example.test/b2');
    final all = await callList('Source.List', ['']);
    final ids = [all[0]['id'] as int, all[1]['id'] as int];

    await call('Source.SetEnabledBatch', [ids, false]);
    expect(
      (await callList('Source.List', [''])).every((s) => s['enabled'] == false),
      isTrue,
    );

    await call('Source.SetEnabledExploreBatch', [ids, false]);
    final detail = await callMap('Source.Get', [ids.first]);
    expect(jsonDecode(detail['raw'] as String)['enabledExplore'], isFalse);

    await call('Source.MoveTop', [
      [ids.last],
    ]);
    expect((await callList('Source.List', [''])).first['id'], ids.last);
    await call('Source.MoveBottom', [
      [ids.last],
    ]);
    expect((await callList('Source.List', [''])).last['id'], ids.last);

    await call('Source.Reorder', [ids.reversed.toList()]);
    expect((await callList('Source.List', [''])).first['id'], ids.last);

    await call('Source.DeleteBatch', [ids]);
    expect(await callList('Source.List', ['']), isEmpty);
  });

  test('变量与 Cookie 清理', () async {
    final view = await addSource('https://example.test/v');
    final id = view['id'] as int;
    await call('Source.SetVariable', [id, '{"cookies":"x=1"}']);
    expect(
      (await callMap('Source.GetVariable', [id]))['variable'],
      '{"cookies":"x=1"}',
    );
    await call('Source.SetVariable', [id, '']);
    expect(
      jsonDecode(
        (await callMap('Source.GetVariable', [id]))['variable'] as String,
      ),
      isEmpty,
    );
    await call('Source.ClearCookie', [id]); // 幂等
  });

  test('校验与订阅 CRUD', () async {
    await addSource('https://example.test/check');
    final checked = await callList('Source.Validate', [
      const <int>[],
      {'Search': true, 'Info': true, 'TOC': true, 'Content': true},
    ]);
    expect(checked.single['ok'], isTrue);

    final sub = await callMap('Source.SaveSubscription', [
      0,
      '订阅',
      'https://example.test/sub.json',
      true,
      1,
    ]);
    final subId = sub['id'] as int;
    expect((await callList('Source.ListSubscriptions')).length, 1);
    expect((await callMap('Source.GetSubscription', [subId]))['name'], '订阅');

    await call('Source.SetSubscriptionEnabled', [subId, false]);
    expect(
      (await callMap('Source.GetSubscription', [subId]))['enabled'],
      isFalse,
    );
    expect(await callList('Source.SyncAllSubscriptions'), isEmpty);

    await call('Source.DeleteSubscription', [subId]);
    expect(await callList('Source.ListSubscriptions'), isEmpty);
  });
}
