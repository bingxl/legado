import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/bridge/legado_client.dart';
import 'package:legado/features/settings/settings_api.dart';
import 'package:legado/features/settings/settings_models.dart';
import 'package:legado/features/settings/settings_store.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

/// 假 core：只实现设置模块的五个方法，行为与 Go 侧一致
/// （Update 合并增量并回全量、Reset 恢复 Schema 默认值、非法值抛 LegadoError）。
class _FakeCore {
  _FakeCore()
    : schemaJson = _fixture('settings_schema.json'),
      current = <String, String>{
          for (final entry in _fixture('settings_values.json').entries)
          entry.key: '${entry.value}',
      } {
    for (final section in _schema.sections) {
      for (final item in section.items) {
        defaults[item.key] = item.defaultRaw;
      }
    }
  }

  final Map<String, dynamic> schemaJson;
  SettingsSchema get _schema => SettingsSchema.fromJson(schemaJson);
  final Map<String, String> current;
  final Map<String, String> defaults = <String, String>{};

  final List<({String method, List<Object?> args})> calls =
      <({String method, List<Object?> args})>[];

  bool failUpdate = false;
  int updateCount = 0;

  Future<Object?> call(String method, List<Object?> args) async {
    calls.add((method: method, args: args));
    switch (method) {
      case SettingsApi.schema:
        return schemaJson;
      case SettingsApi.values:
        return Map<String, String>.from(current);
      case SettingsApi.update:
        updateCount++;
        if (failUpdate) {
          throw const LegadoError('invalid', 'reader.fontSize 超出范围');
        }
        final patch = args.first as Map;
        patch.forEach((key, value) => current['$key'] = '$value');
        return Map<String, String>.from(current);
      case SettingsApi.reset:
        final keys = <String>[for (final key in args.first as List) '$key'];
        if (keys.isEmpty) {
          current.addAll(defaults);
        } else {
          for (final key in keys) {
            final value = defaults[key];
            if (value != null) current[key] = value;
          }
        }
        return Map<String, String>.from(current);
      case SettingsApi.reader:
        return const <String, Object?>{};
    }
    return null;
  }

  int countOf(String method) =>
      calls.where((call) => call.method == method).length;
}

void main() {
  late _FakeCore core;
  late SettingsStore store;

  setUp(() {
    core = _FakeCore();
    store = SettingsStore(caller: core.call);
  });

  tearDown(() => store.dispose());

  test('load 并发拉 Schema + Values 并填充默认值', () async {
    expect(store.status, SettingsStatus.idle);
    await store.load();

    expect(store.status, SettingsStatus.ready);
    expect(store.error, isNull);
    expect(core.countOf(SettingsApi.schema), 1);
    expect(core.countOf(SettingsApi.values), 1);
    expect(store.values['reader.fontSize'], '20');
    expect(store.values.length, core.current.length);

    final general = store.sectionsForPage('general');
    expect(general.length, 1);
    expect(general.single.items.single.key, 'general.promptAddToShelf');
  });

  test('readerConfig 与 Settings.Reader fixture 一致', () async {
    await store.load();
    expect(store.readerConfig.toJson(), _fixture('settings_reader.json'));

    // 本地改动立即反映到强类型配置，阅读器不必等保存完成。
    await store.setValue('reader.fontSize', '26');
    expect(store.readerConfig.fontSize, 26);
  });

  test('load 失败进入 error 且可重试', () async {
    final failing = SettingsStore(
      caller: (method, args) async =>
          throw const LegadoError('CORE_UNAVAILABLE', '未连接'),
    );
    addTearDown(failing.dispose);

    await failing.load();
    expect(failing.status, SettingsStatus.error);
    expect(failing.error, 'CORE_UNAVAILABLE: 未连接');

    // 仍在 error 上时再次 load（非 force）也应重新尝试，而不是永远卡住。
    await failing.load();
    expect(failing.status, SettingsStatus.error);
  });

  test('成功加载后非 force 的 load 不再打网络', () async {
    await store.load();
    final before = core.calls.length;
    await store.load();
    expect(core.calls.length, before);
  });

  test('setValue 本地立即可见，防抖后只发一次 Update', () async {
    await store.load();

    var notified = 0;
    store.addListener(() => notified++);
    await store.setValue('reader.fontSize', '26');
    expect(store.values['reader.fontSize'], '26');
    expect(notified, 1);
    expect(core.updateCount, 0, reason: '防抖期内不应发请求');

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(core.updateCount, 1);
    final update = core.calls.lastWhere(
      (call) => call.method == SettingsApi.update,
    );
    expect(update.args.single, <String, String>{'reader.fontSize': '26'});
    expect(store.values['reader.fontSize'], '26');
  });

  test('连续改多项合并成一次 Update', () async {
    await store.load();
    await store.setValue('reader.fontSize', '24');
    await store.setValue('reader.theme', 'night');
    await store.setValue('reader.fontSize', '25');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(core.updateCount, 1);
    final update = core.calls.lastWhere(
      (call) => call.method == SettingsApi.update,
    );
    expect(update.args.single, <String, String>{
      'reader.fontSize': '25',
      'reader.theme': 'night',
    });
  });

  test('服务端拒绝时回滚到确认值并记下错误', () async {
    await store.load();
    core.failUpdate = true;

    await store.setValue('reader.fontSize', '999');
    expect(store.values['reader.fontSize'], '999');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(core.updateCount, 1);
    expect(store.values['reader.fontSize'], '20');
    expect(store.lastError, 'invalid: reader.fontSize 超出范围');
    expect(store.lastErrorSeq, 1);
  });

  test('保存失败时不清掉更新的本地改动', () async {
    await store.load();
    core.failUpdate = true;
    await store.setValue('reader.fontSize', '999');
    // 请求发出（防抖到期）后用户又改了一次，回滚不应覆盖这次改动。
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await store.setValue('reader.fontSize', '22');

    expect(store.values['reader.fontSize'], '22');
  });

  test('resetAll 调 Settings.Reset 且参数为 [[]]', () async {
    await store.load();
    await store.setValue('reader.fontSize', '26');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    await store.resetAll();

    final reset = core.calls.lastWhere(
      (call) => call.method == SettingsApi.reset,
    );
    expect(reset.args, <Object?>[<String>[]]);
    expect(reset.args.first, isEmpty);
    expect(store.values['reader.fontSize'], '20');
  });

  test('resetKeys 只重置指定键', () async {
    await store.load();
    await store.setValue('reader.fontSize', '26');
    await store.setValue('reader.theme', 'night');
    await Future<void>.delayed(const Duration(milliseconds: 400));

    await store.resetKeys(<String>['reader.theme']);

    final reset = core.calls.lastWhere(
      (call) => call.method == SettingsApi.reset,
    );
    expect(reset.args.single, <String>['reader.theme']);
    expect(store.values['reader.theme'], 'paper');
    expect(store.values['reader.fontSize'], '26');
  });

  test('displayValue 按 kind 格式化', () async {
    await store.load();
    final schema = store.schema!;
    expect(
      store.displayValue(schema.itemByKey('reader.fontSize')!, '26'),
      '26 px',
    );
    expect(
      store.displayValue(schema.itemByKey('reader.indentFirstLine')!, 'false'),
      '关',
    );
    expect(
      store.displayValue(schema.itemByKey('reader.pageTurn')!, 'simulation'),
      '仿真',
    );
    expect(store.displayValue(schema.itemByKey('reader.lineHeight')!, '1.8'),
        '1.8 倍');
  });
}
