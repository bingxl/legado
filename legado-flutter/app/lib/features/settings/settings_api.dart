import '../../core/bridge/legado_client.dart';

/// 设置域的控制面方法封装。
///
/// 方法名刻意留在本 feature 内，而不是追加到共享的 `core/bridge/api.dart`：
/// 那是并行开发时的公共写入点，set 模块还没定型，先局部维护避免冲突。
/// 参数全部是位置参数（Settings.Update 是唯一一个 map 参数）。
class SettingsApi {
  SettingsApi._();

  static const schema = 'Settings.Schema';
  static const values = 'Settings.Values';
  static const update = 'Settings.Update';
  static const reset = 'Settings.Reset';
  static const reader = 'Settings.Reader';

  static LegadoClient get _c => LegadoClient.instance;

  /// Schema 是页面结构的唯一来源，UI 不硬编码分组与控件类型。
  static Future<Map<String, dynamic>> fetchSchema() async =>
      _map(await _c.call(schema));

  /// 全部有效值，键与 Schema item.key 一一对应，值统一为字符串。
  static Future<Map<String, dynamic>> fetchValues() async =>
      _map(await _c.call(values));

  /// 增量保存，返回保存后的全量有效值（服务端已夹区间/对齐 step/校验下拉值）。
  static Future<Map<String, dynamic>> updateValues(
    Map<String, String> patch,
  ) async => _map(await _c.call(update, [patch]));

  /// keys 为空表示全部重置。注意外层 args 仍是一个数组，故实际为 `[[]]`。
  static Future<Map<String, dynamic>> resetValues(List<String> keys) async =>
      _map(await _c.call(reset, [keys]));

  /// 强类型阅读配置。设置页不直接用它（本地乐观值要即时生效），
  /// 保留给阅读器/校验脚本对照。
  static Future<Map<String, dynamic>> fetchReader() async =>
      _map(await _c.call(reader));

  static Map<String, dynamic> _map(dynamic data) {
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}
