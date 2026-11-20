import 'setting_schema.dart';

/// 从 Schema 汇总「未落库时的基底值」。
///
/// 键集合与 Schema 完全一致：`Settings.Values` 必须让 UI 第一次打开就能渲染出
/// 所有项（UI 用 `values[key] ?? item.defaultRaw` 兜底，但 CLI 与校验脚本没有
/// 那层兜底，少一个键就是 undefined）。值一律字符串，与 [SettingItem.defaultRaw]
/// 同构。
Map<String, String> defaultValues(SettingsSchema schema) {
  final result = <String, String>{};
  for (final section in schema.sections) {
    for (final item in section.items) {
      result[item.key] = item.defaultRaw;
    }
  }
  return result;
}
