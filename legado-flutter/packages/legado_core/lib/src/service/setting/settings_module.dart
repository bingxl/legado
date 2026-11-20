import '../../kernel/errors.dart';
import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import 'dao_settings_storage.dart';
import 'setting_schema.dart';
import 'settings_service.dart';

/// 设置域模块：把 [SettingsService] 接到注册表上。
///
/// 依赖 `store`（`app_settings` 表）即可，不依赖网络/规则/JS —— 所以它可以
/// 和 `shelf` 同时开工，也是「内核能不能跑通」的最短验证路径：
/// `legado call Settings.Values` 有输出，说明装配、迁移、信封三条链路都活着。
class SettingsModule extends CoreModule {
  SettingsService? _service;

  @override
  String get name => 'settings';

  @override
  List<String> get dependsOn => const ['store'];

  /// 诊断用：测试与 CLI 可以拿到同一个 service 实例。
  SettingsService get service {
    final service = _service;
    if (service == null) {
      throw StateError('settings 模块尚未 register');
    }
    return service;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) {
      throw StateError('settings 依赖 store，但 store 尚未 migrate');
    }
    final service = SettingsService(
      storage: DaoSettingsStorage(store.daos.settings),
      schema: defaultSettingsSchema,
    );
    _service = service;

    registry.method(
      'Settings.Schema',
      (args) async => service.schemaJson(),
      doc: '设置结构（驱动 UI 渲染的完整声明）',
    );

    registry.method(
      'Settings.Values',
      (args) async => service.values(),
      doc: '默认值 + 已落库，值一律字符串',
    );

    registry.method(
      'Settings.Update',
      (args) async => service.update(_toStringMap(_arg(args, 0))),
      params: const ['patch map'],
      doc: '增量保存，返回保存后的全量；patch 为 null 报 INVALID_ARGUMENT',
    );

    registry.method(
      'Settings.Reset',
      (args) async => service.reset(_toStringList(_arg(args, 0))),
      params: const ['keys list<string>'],
      doc: '重置指定项；keys 为空或 null 表示全部重置',
    );

    registry.method(
      'Settings.Reader',
      (args) async => service.reader().toJson(),
      doc: '强类型阅读配置；解析失败静默退回默认值，永不抛错',
    );
  }

  @override
  Future<void> close() async {
    _service = null;
  }
}

Object? _arg(List<Object?> args, int index) =>
    index < args.length ? args[index] : null;

/// 把信封里的 JSON Map 收敛成 `Map<String,String>`。
///
/// 值不强制要求 String：UI 的滑块批次里偶尔会混进 `int`/`double`（Dart 侧
/// `num.toString()` 得到 `20` 而不是 `20.0` 这层已经够用），`bool` 也允许。
/// 但**语义校验**仍在 service 里 —— 例如给 switch 传 `42` 会先变成 `"42"`，
/// 再被 service 判成「需要 true/false」，报错信息仍然指向那个键。
Map<String, String>? _toStringMap(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw LegadoException(
      ErrorCode.invalid,
      '需要 Map<String,String>，收到 ${raw.runtimeType}',
    );
  }
  final result = <String, String>{};
  for (final entry in raw.entries) {
    result['${entry.key}'] = _stringify(entry.value);
  }
  return result;
}

List<String>? _toStringList(Object? raw) {
  if (raw == null) return null;
  if (raw is! List) {
    throw LegadoException(
      ErrorCode.invalid,
      '需要 List<String>，收到 ${raw.runtimeType}',
    );
  }
  return <String>[for (final item in raw) _stringify(item)];
}

/// JSON 值 → 字符串。`null` 保留成空串而不是 "null"：整批 update 里出现
/// `{"reader.fontSize": null}` 时，用户的意思多半是「没填」，空串会走
/// 「需要数字」的报错路径，比静默写进 `"null"` 更好排查。
String _stringify(Object? value) {
  if (value == null) return '';
  if (value is double && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return '$value';
}
