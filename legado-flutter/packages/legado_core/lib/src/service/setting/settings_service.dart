import '../../kernel/errors.dart';
import 'defaults.dart';
import 'reader_config.dart';
import 'setting_schema.dart';
import 'settings_storage.dart';

/// 设置域的服务实现，对应契约表的 5 个方法。
///
/// 职责边界：Schema 决定「有哪些项、合法范围是什么」，存储只负责落盘，
/// 本类把两者拼成 `Settings.Values` 并做写路径校验。所有校验都在这里，
/// 不依赖 UI —— CLI（`legado settings set reader.fontSize 999`）与 UI 走同一条路径。
///
/// ## 写路径的三条规则
///
/// 1. **未知 key 忽略**，不报错。Schema 演进时旧 UI 的防抖批次里可能带着已删除的
///    键，整批报错会让用户连字号都调不了；忽略的代价只是那一个键没保存。
/// 2. **数值越界钳制**，不报错。滑块拖到边界是合法操作，报错只会弹一个没用的 toast。
/// 钳制后再按 `step` 吸附，保证 Values 与 UI 滑块位置一致。
/// 3. **无法解释的值报 `INVALID_ARGUMENT`**：非数字的 slider/number、不在
///    `options` 里的 select、非布尔的 switch。这类值没有「合理近似」可猜，
///    静默替换成默认值反而会让用户以为保存成功了。
class SettingsService {
  SettingsService({
    required SettingsStorage storage,
    required SettingsSchema schema,
  }) : _storage = storage,
       _schema = schema,
       _defaults = defaultValues(schema) {
    for (final section in schema.sections) {
      for (final item in section.items) {
        _items[item.key] = item;
      }
    }
  }

  final SettingsStorage _storage;
  final SettingsSchema _schema;

  /// 键 → 项。Schema 很小（十几个），用 Map 索引足够，不必每次线性找。
  final Map<String, SettingItem> _items = <String, SettingItem>{};

  /// 未落库时的基底值。
  final Map<String, String> _defaults;

  /// `Settings.Schema`：驱动 UI 渲染的完整声明。
  Map<String, Object?> schemaJson() => _schema.toJson();

  /// `Settings.Values`：默认值 + 已落库覆盖。
  ///
  /// 读路径也做归一化：
  ///   * 库里不认识/已废弃的键直接丢掉，不然 Values 会越长越脏；
  ///   * 解析不了的值退回默认值，越界的值钳回区间（旧版 Go 内核或手工改库
  ///     都可能留下这种值）。这样返回值永远是一份「可以原样交给 UI 渲染」的快照。
  Map<String, String> values() {
    final result = Map<String, String>.from(_defaults);
    final stored = _storage.getAll();
    for (final entry in stored.entries) {
      final item = _items[entry.key];
      if (item == null) continue;
      final normalized = _tryNormalize(item, entry.value);
      if (normalized != null) result[entry.key] = normalized;
    }
    return result;
  }

  /// `Settings.Update`：增量保存，返回保存后的全量有效值。
  ///
  /// `patch` 为 null 时报 [ErrorCode.invalid]（契约表明确要求）；空 Map 是合法
  /// 的「无改动」，返回当前全量即可。
  Future<Map<String, String>> update(Map<String, String>? patch) async {
    if (patch == null) {
      throw const LegadoException(
        ErrorCode.invalid,
        'Settings.Update 需要 patch，收到 null',
      );
    }
    final normalized = <String, String>{};
    for (final entry in patch.entries) {
      final item = _items[entry.key];
      if (item == null) continue;
      normalized[entry.key] = _normalize(item, entry.value);
    }
    if (normalized.isNotEmpty) {
      await _storage.putAll(normalized);
    }
    return values();
  }

  /// `Settings.Reset`：`keys` 为空（或 null）表示全部重置。
  ///
  /// 重置 = 删掉落库记录，让默认值重新生效；不认识的 key 忽略。
  Future<Map<String, String>> reset(List<String>? keys) async {
    final targets = <String>[];
    if (keys == null || keys.isEmpty) {
      targets.addAll(_items.keys);
    } else {
      for (final key in keys) {
        if (_items.containsKey(key)) targets.add(key);
      }
    }
    if (targets.isNotEmpty) {
      await _storage.removeAll(targets);
    }
    return values();
  }

  /// `Settings.Reader`：强类型阅读配置。解析失败静默退回默认值，永不抛错。
  ReaderConfig reader() => ReaderConfig.fromMap(values());

  /// 归一化并校验一个值；非法时抛 `INVALID_ARGUMENT`。
  String _normalize(SettingItem item, String raw) {
    switch (item.kind) {
      case SettingKind.switchToggle:
        final flag = _parseFlag(raw);
        if (flag == null) {
          throw _invalid(item, raw, '需要 true/false');
        }
        return flag ? 'true' : 'false';

      case SettingKind.slider:
      case SettingKind.number:
        final parsed = double.tryParse(raw.trim());
        if (parsed == null || !parsed.isFinite) {
          throw _invalid(item, raw, '需要数字');
        }
        return _bounded(item, parsed);

      case SettingKind.select:
        final options = item.options ?? const <SettingOption>[];
        final value = raw.trim();
        for (final option in options) {
          if (option.value == value) return value;
        }
        throw _invalid(item, raw, '不在可选项内');

      case SettingKind.text:
        return raw;
    }
  }

  /// 读路径用的宽松版本：非法值返回 null，由调用方保留默认值。
  String? _tryNormalize(SettingItem item, String raw) {
    try {
      return _normalize(item, raw);
    } on LegadoException {
      return null;
    }
  }

  /// 钳区间 + 吸附 step。
  ///
  /// `min` 缺失按 0（UI 约定），`max` 缺失表示无上限（UI 里等价于 0）。
  /// 顺序是「先钳、再吸附、再钳一次」：吸附可能把值推出上界
  /// （min=12/max=40/step=7 时 39 会吸到 42），最后一步保证不越界。
  String _bounded(SettingItem item, double value) {
    final min = (item.min ?? 0).toDouble();
    final max = item.max?.toDouble();
    final hasMax = max != null && max > min;

    var result = value < min ? min : value;
    if (hasMax && result > max) result = max;

    final step = item.step?.toDouble();
    if (step != null && step > 0) {
      result = (result / step).round() * step;
      if (result < min) result = min;
      if (hasMax && result > max) result = max;
    }
    return settingNumberText(result);
  }

  bool? _parseFlag(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'on':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'off':
      case 'no':
        return false;
    }
    return null;
  }

  LegadoException _invalid(SettingItem item, String raw, String reason) =>
      LegadoException(
        ErrorCode.invalid,
        '设置项 ${item.key} 的值非法: "$raw"（$reason）',
      );
}
