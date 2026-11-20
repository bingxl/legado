import 'row_utils.dart';

/// 全量设置表。
///
/// Kotlin 版用 SharedPreferences，纯 Dart 内核没有平台存储，改用一张表。
/// 值**一律存字符串**（数字/布尔由上层转换），和契约表「值一律字符串」保持一致。
class AppSetting {
  AppSetting({required this.key, this.value});

  static const String tableAppSettings = 'app_settings';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `app_settings` (
  `key` TEXT NOT NULL,
  `value` TEXT,
  PRIMARY KEY(`key`)
)''';

  String key;
  String? value;

  factory AppSetting.fromRow(Map<String, Object?> row) => AppSetting(
        key: asString(row['key']),
        value: asStringOrNull(row['value']),
      );

  Map<String, Object?> toRow() => {
        'key': key,
        'value': value,
      };
}
