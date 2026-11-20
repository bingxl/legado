import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/core.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/setting/settings_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 设置域的「接线」测试：验证 5 个方法真的挂上了、参数按契约收敛、
/// 落盘走的是 sqlite 而不是内存，并且 `LegadoCore` 装配 + 信封两条链路都通。
void main() {
  late Directory home;
  late StoreModule store;
  late SettingsModule settings;
  late Registry registry;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-settings-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    settings = SettingsModule();
    settings.register(registry, ctx());
  });

  tearDown(() async {
    await settings.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  test('依赖声明：settings 依赖 store', () {
    expect(settings.name, 'settings');
    expect(settings.dependsOn, contains('store'));
  });

  test('Settings.Schema 返回三个页面与可渲染的 items', () async {
    final schema = await call('Settings.Schema') as Map<String, Object?>;
    expect(schema['version'], isA<int>());
    expect(schema['pages'], containsAll(<String>['read', 'theme', 'general']));

    final sections = schema['sections'] as List<Object?>;
    expect(sections, isNotEmpty);
    for (final section in sections.cast<Map<String, Object?>>()) {
      expect(section['key'], isA<String>());
      expect(section['page'], isA<String>());
      final items = section['items'] as List<Object?>;
      expect(items, isNotEmpty);
      for (final item in items.cast<Map<String, Object?>>()) {
        expect(item['key'], isA<String>());
        expect(item['kind'], isA<String>());
        expect(item.containsKey('default'), isTrue);
      }
    }
  });

  test('Values 未落库时就是默认值，且键集合与 Schema 一致', () async {
    final schema = await call('Settings.Schema') as Map<String, Object?>;
    final keys = <String>[];
    for (final section in (schema['sections'] as List<Object?>)
        .cast<Map<String, Object?>>()) {
      for (final item in (section['items'] as List<Object?>)
          .cast<Map<String, Object?>>()) {
        keys.add(item['key'] as String);
      }
    }

    final values = await call('Settings.Values') as Map<String, Object?>;
    expect(values.keys.toSet(), keys.toSet());
    expect(values['reader.fontSize'], '20');
    expect(values['reader.pageTurn'], 'cover');
  });

  test('Update 写入后 Values 读得到，且真的落到 app_settings 表', () async {
    await call('Settings.Update', [
      <String, String>{'reader.fontSize': '24'},
    ]);
    expect(store.daos.settings.get('reader.fontSize'), '24');
    expect((await call('Settings.Values') as Map)['reader.fontSize'], '24');
  });

  test('Update 允许 num/bool 混进 patch（UI 防抖批次常见）', () async {
    final values = await call('Settings.Update', [
      <String, Object?>{'reader.fontSize': 26, 'reader.indentFirstLine': false},
    ]) as Map<String, Object?>;
    expect(values['reader.fontSize'], '26');
    expect(values['reader.indentFirstLine'], 'false');
  });

  test('Update 越界钳制到区间边界', () async {
    final values = await call('Settings.Update', [
      <String, String>{'reader.fontSize': '999'},
    ]) as Map<String, Object?>;
    expect(values['reader.fontSize'], '40');
  });

  test('Update 非法值报 INVALID_ARGUMENT，且不写入', () async {
    await expectLater(
      call('Settings.Update', [
        <String, String>{'reader.fontSize': 'abc'},
      ]),
      throwsA(
        isA<LegadoException>().having(
          (e) => e.code,
          'code',
          ErrorCode.invalid,
        ),
      ),
    );
    expect(store.daos.settings.get('reader.fontSize'), isNull);
  });

  test('Update 的 patch 为 null 报 INVALID_ARGUMENT', () async {
    await expectLater(
      call('Settings.Update', [null]),
      throwsA(
        isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid),
      ),
    );
  });

  test('Update 参数不是 Map 时报参数错误而不是 TypeError', () async {
    await expectLater(
      call('Settings.Update', ['not-a-map']),
      throwsA(
        isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid),
      ),
    );
  });

  test('Reset 指定键回到默认值，库里记录被删除', () async {
    await call('Settings.Update', [
      <String, String>{'reader.fontSize': '30', 'reader.theme': 'night'},
    ]);
    final values = await call('Settings.Reset', [
      <String>['reader.fontSize'],
    ]) as Map<String, Object?>;
    expect(values['reader.fontSize'], '20');
    expect(values['reader.theme'], 'night');
    expect(store.daos.settings.get('reader.fontSize'), isNull);
  });

  test('Reset 传空列表等于全部重置', () async {
    await call('Settings.Update', [
      <String, String>{'reader.fontSize': '30', 'reader.showPageNumber': 'false'},
    ]);
    final values = await call('Settings.Reset', [
      const <String>[],
    ]) as Map<String, Object?>;
    expect(values['reader.fontSize'], '20');
    expect(values['reader.showPageNumber'], 'true');
    expect(store.daos.settings.count(), 0);
  });

  test('Reader 返回强类型配置，字段与契约表一致', () async {
    await call('Settings.Update', [
      <String, String>{'reader.fontSize': '22', 'reader.theme': 'night'},
    ]);
    final config = await call('Settings.Reader') as Map<String, Object?>;
    expect(config.keys.toSet(), <String>{
      'fontSize',
      'lineHeight',
      'paragraphSpacing',
      'indentFirstLine',
      'paddingHorizontal',
      'paddingVertical',
      'pageTurn',
      'theme',
      'showPageNumber',
      'textJustify',
      'promptAddToShelf',
    });
    expect(config['fontSize'], 22);
    expect(config['theme'], 'night');
  });

  test('库里存了脏值也不会让 Reader 抛错（退回默认值）', () async {
    await store.daos.settings.put('reader.fontSize', 'NaN');
    await store.daos.settings.put('reader.theme', '不存在的主题');
    final config = await call('Settings.Reader') as Map<String, Object?>;
    expect(config['fontSize'], 20);
    expect(config['theme'], 'paper');
  });

  group('LegadoCore 装配', () {
    test('init 后 Settings.* 与方法表都能看到', () async {
      final core = LegadoCore.instance;
      // 上面 setUp 已经打开过一个库，这里换独立目录，避免 WAL 句柄打架。
      final coreHome = await Directory.systemTemp.createTemp('legado-core-settings');
      await core.init(homeDir: coreHome.path, version: 'test', host: 'test');
      addTearDown(() async {
        await core.close();
        if (coreHome.existsSync()) coreHome.deleteSync(recursive: true);
      });

      final methods = core.methods('Settings').map((m) => m.name).toList();
      expect(methods, <String>[
        'Settings.Reader',
        'Settings.Reset',
        'Settings.Schema',
        'Settings.Update',
        'Settings.Values',
      ]);

      final data = await core.call('Settings.Values') as Map<String, Object?>;
      expect(data['reader.fontSize'], '20');
    });

    test('信封链路：JSON 进、JSON 出，非法参数也返回 ok:false', () async {
      final core = LegadoCore.instance;
      final coreHome = await Directory.systemTemp.createTemp('legado-core-envelope');
      await core.init(homeDir: coreHome.path, version: 'test', host: 'test');
      addTearDown(() async {
        await core.close();
        if (coreHome.existsSync()) coreHome.deleteSync(recursive: true);
      });

      final ok = jsonDecode(
        await core.handle(
          jsonEncode({
            'id': 1,
            'method': 'Settings.Update',
            'args': [
              {'reader.lineHeight': '2.1'},
            ],
          }),
        ),
      ) as Map<String, Object?>;
      expect(ok['ok'], isTrue);
      expect((ok['data'] as Map)['reader.lineHeight'], '2.1');

      final bad = jsonDecode(
        await core.handle(
          jsonEncode({
            'id': 2,
            'method': 'Settings.Update',
            'args': [null],
          }),
        ),
      ) as Map<String, Object?>;
      expect(bad['ok'], isFalse);
      expect((bad['err'] as Map)['code'], ErrorCode.invalid);
    });
  });
}
