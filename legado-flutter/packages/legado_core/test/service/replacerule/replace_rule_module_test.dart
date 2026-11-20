import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/replacerule/replace_rule_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 替换规则域接线测试：一组多条规则的 raw 映射、导入导出与分组语义。
void main() {
  late Directory home;
  late StoreModule store;
  late ReplaceRuleModule module;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-replace-rule-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    module = ReplaceRuleModule();
    module.register(registry, ctx());
  });

  tearDown(() async {
    await module.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  const raw = '[{"pattern":"<script[\\\\s\\\\S]*?</script>","replacement":"",'
      '"isRegex":true},{"pattern":"广告","replacement":"","isRegex":false}]';

  test('依赖与 7 个方法注册', () {
    expect(module.name, 'replacerule');
    expect(module.dependsOn, contains('store'));
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>[
        'ReplaceRule.List',
        'ReplaceRule.Get',
        'ReplaceRule.Save',
        'ReplaceRule.Delete',
        'ReplaceRule.SetEnabled',
        'ReplaceRule.Import',
        'ReplaceRule.Export',
      ]),
    );
  });

  test('Save 一组两条 → List/Get 读回同一 raw；底层是两行', () async {
    final view = await callMap('ReplaceRule.Save', [0, '净化', '通用', raw, true, 5]);
    expect(view['id'], isA<int>());
    expect(view['name'], '净化');
    expect(view['enabled'], isTrue);
    final parsed = jsonDecode(view['raw'] as String) as List;
    expect(parsed.length, 2);

    final list = await callList('ReplaceRule.List');
    expect(list.length, 1);
    expect(list.single['raw'], view['raw']);
    expect(store.daos.replaceRule.all.length, 2);

    final got = await callMap('ReplaceRule.Get', [view['id']]);
    expect(got['raw'], view['raw']);
  });

  test('SetEnabled 与 Delete 作用于整组', () async {
    final view = await callMap('ReplaceRule.Save', [0, '组', '', raw, true, 1]);
    final id = view['id'] as int;
    await call('ReplaceRule.SetEnabled', [id, false]);
    expect(store.daos.replaceRule.all.every((rule) => !rule.isEnabled), isTrue);
    expect((await callList('ReplaceRule.List')).single['enabled'], isFalse);

    await call('ReplaceRule.Delete', [id]);
    expect(await callList('ReplaceRule.List'), isEmpty);
    await expectLater(
      call('ReplaceRule.Get', [id]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.notFound)),
    );
  });

  test('raw 空串兜成 []，重名组被覆盖而不是重复', () async {
    await call('ReplaceRule.Save', [0, '空组', '', raw, true, 1]);
    final empty = await callMap('ReplaceRule.Save', [0, '空组', '', '', true, 1]);
    expect(jsonDecode(empty['raw'] as String), isEmpty);
    // 空规则组不落行，List 自然不再出现它。
    expect(await callList('ReplaceRule.List'), isEmpty);
    expect(store.daos.replaceRule.all, isEmpty);
  });

  test('Import 兼容 replaceRule 包裹与覆盖策略；Export base64', () async {
    final payload = jsonEncode({
      'replaceRule': [
        {'name': '导入组', 'group': 'G', 'enabled': true, 'order': 1, 'raw': raw},
      ],
    });
    final encoded = base64Encode(utf8.encode(payload));

    final result = await callMap('ReplaceRule.Import', [encoded, false]);
    expect(result['imported'], 1);
    expect(result['rules'], hasLength(1));

    final again = await callMap('ReplaceRule.Import', [encoded, false]);
    expect(again['skipped'], 1);
    final overwrite = await callMap('ReplaceRule.Import', [encoded, true]);
    expect(overwrite['updated'], 1);

    final exported = await call('ReplaceRule.Export', [const <int>[]]) as String;
    final items = jsonDecode(utf8.decode(base64Decode(exported))) as List;
    expect(items, isNotEmpty);
    expect((items.first as Map)['name'], '导入组');
  });

  test('非法 raw 抛 INVALID_ARGUMENT', () async {
    await expectLater(
      call('ReplaceRule.Save', [0, '坏规则', '', '{}', true, 0]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.invalid)),
    );
  });
}
