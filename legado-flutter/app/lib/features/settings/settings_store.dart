import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/bridge/legado_client.dart';
import 'settings_api.dart';
import 'settings_models.dart';

/// 调用器抽象：默认走 [LegadoClient]，单测注入假实现。
typedef SettingsCaller =
    Future<Object?> Function(String method, List<Object?> args);

enum SettingsStatus { idle, loading, ready, error }

/// 设置中心的状态容器。
///
/// 三条约束决定了这里的写法：
///   1. 页面结构只来自 Schema —— UI 不硬编码分组/控件，后端加一项不用改前端；
///   2. 滑块要跟手 —— 改动先落本地并立即 notify，再用 250ms 防抖合并成一次 Update；
///   3. 服务端是唯一真相 —— Update 返回全量值，失败则回滚，避免本地和服务端漂移。
class SettingsStore extends ChangeNotifier {
  SettingsStore({SettingsCaller? caller}) : _caller = caller ?? _defaultCaller;

  static final SettingsStore instance = SettingsStore();

  static Future<Object?> _defaultCaller(String method, List<Object?> args) =>
      LegadoClient.instance.call(method, args);

  /// 防抖窗口。拖滑块只在 onChangeEnd 落盘，连续点开关时也能合并成一次请求。
  static const debounce = Duration(milliseconds: 250);

  final SettingsCaller _caller;

  SettingsStatus _status = SettingsStatus.idle;
  String? _error;
  SettingsSchema? _schema;

  /// 当前展示值（含乐观改动）。
  final Map<String, String> _values = <String, String>{};

  /// 服务端确认过的最新值，用于失败回滚。
  final Map<String, String> _confirmed = <String, String>{};

  /// 尚未发出去的增量改动。
  final Map<String, String> _pending = <String, String>{};

  Timer? _debounceTimer;
  bool _loading = false;
  String? _lastError;
  int _lastErrorSeq = 0;

  SettingsStatus get status => _status;
  String? get error => _error;
  SettingsSchema? get schema => _schema;
  Map<String, String> get values => Map<String, String>.unmodifiable(_values);

  /// 最近一次保存失败的原因；[lastErrorSeq] 每次失败自增，页面据此只弹一次提示。
  String? get lastError => _lastError;
  int get lastErrorSeq => _lastErrorSeq;

  List<SettingsSection> sectionsForPage(String page) =>
      _schema?.sectionsForPage(page) ?? const <SettingsSection>[];

  /// 强类型阅读配置。缺项用 Schema 声明的默认值补齐，
  /// 再交给 [ReaderConfig] 做类型兜底——任何脏数据都只会回到默认值。
  ReaderConfig get readerConfig {
    final effective = <String, String>{};
    for (final section in _schema?.sections ?? const <SettingsSection>[]) {
      for (final item in section.items) {
        if (item.defaultValue != null) effective[item.key] = item.defaultRaw;
      }
    }
    effective.addAll(_values);
    return ReaderConfig.fromValues(effective);
  }

  Future<void> load({bool force = false}) async {
    if (_loading) return;
    if (_status == SettingsStatus.ready && !force) return;
    _loading = true;
    _status = SettingsStatus.loading;
    _error = null;
    notifyListeners();
    try {
      final results = await Future.wait(<Future<Object?>>[
        _caller(SettingsApi.schema, const <Object?>[]),
        _caller(SettingsApi.values, const <Object?>[]),
      ]);
      _schema = SettingsSchema.fromJson(results[0]);
      final values = _stringMap(results[1]);
      _values
        ..clear()
        ..addAll(values);
      _confirmed
        ..clear()
        ..addAll(values);
      _pending.clear();
      _debounceTimer?.cancel();
      _debounceTimer = null;
      _status = SettingsStatus.ready;
    } catch (e) {
      _error = _describe(e);
      _status = SettingsStatus.error;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// 本地立即生效，250ms 后合并落盘。返回的 Future 只代表「已接受本次改动」，
  /// 不代表已保存——保存结果通过 [values]/[lastError] 观察。
  Future<void> setValue(String key, String value) async {
    if (_values[key] == value) return;
    _values[key] = value;
    _pending[key] = value;
    notifyListeners();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(_flush()));
  }

  Future<void> resetAll() => _reset(const <String>[]);

  Future<void> resetKeys(List<String> keys) => _reset(keys);

  Future<void> _reset(List<String> keys) async {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pending.clear();
    try {
      final data = await _caller(SettingsApi.reset, <Object?>[keys]);
      _acceptAll(_stringMap(data));
    } catch (e) {
      _recordError(e);
    }
    notifyListeners();
  }

  Future<void> _flush() async {
    _debounceTimer = null;
    if (_pending.isEmpty) return;
    final batch = Map<String, String>.from(_pending);
    _pending.clear();
    try {
      final data = await _caller(SettingsApi.update, <Object?>[batch]);
      // Update 返回全量有效值：以它为准，但期间用户的新改动优先。
      _stringMap(data).forEach((key, value) {
        _confirmed[key] = value;
        if (!_pending.containsKey(key)) _values[key] = value;
      });
    } catch (e) {
      _recordError(e);
      // 回滚这一批里没被用户再次改过的键，避免把更新的乐观值也冲掉。
      batch.forEach((key, attempted) {
        if (_pending.containsKey(key) || _values[key] != attempted) return;
        final previous = _confirmed[key];
        if (previous == null) {
          _values.remove(key);
        } else {
          _values[key] = previous;
        }
      });
    }
    notifyListeners();
  }

  void _acceptAll(Map<String, String> values) {
    _values
      ..clear()
      ..addAll(values);
    _confirmed
      ..clear()
      ..addAll(values);
  }

  void _recordError(Object error) {
    _lastError = _describe(error);
    _lastErrorSeq++;
  }

  /// 原始值 → 展示文本：开关是开/关，滑块带单位，下拉取 label。
  String displayValue(SettingsItem item, String raw) {
    switch (item.kind) {
      case SettingsKind.toggle:
        final defaultValue = item.defaultValue;
        return settingsBool(raw, defaultValue is bool && defaultValue)
            ? '开'
            : '关';
      case SettingsKind.slider:
      case SettingsKind.number:
        final fallback = item.defaultValue is num
            ? (item.defaultValue as num).toDouble()
            : item.min;
        final text = settingsNumberText(settingsDouble(raw, fallback));
        final unit = item.unit;
        return unit == null ? text : '$text $unit';
      case SettingsKind.select:
        for (final option in item.options) {
          if (option.value == raw) return option.label;
        }
        return raw;
      case SettingsKind.text:
        return raw;
      case SettingsKind.unknown:
        return raw.isEmpty ? '—' : raw;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    super.dispose();
  }

  static Map<String, String> _stringMap(Object? data) {
    if (data is! Map) return <String, String>{};
    final result = <String, String>{};
    data.forEach((key, value) {
      result['$key'] = value == null ? '' : '$value';
    });
    return result;
  }

  static String _describe(Object error) {
    if (error is LegadoError) return '${error.code}: ${error.message}';
    return '$error';
  }
}
