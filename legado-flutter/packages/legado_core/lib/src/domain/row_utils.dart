/// SQLite 行与 Dart 值之间的转换工具。
///
/// 单独放一份而不是每个实体各写一遍：一旦某处忘了 `num -> int`，
/// 从 `sqlite3` 读出来的 `INTEGER` 在部分平台会是 `double`，
/// 表现为「字段变成 0」这种极难定位的问题。
library;

/// 取整数，兼容 `int` / `double` / `null`。
int asInt(Object? value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

/// 取可空整数。
int? asIntOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// SQLite 用 0/1 存布尔。
bool asBool(Object? value, {bool fallback = false}) {
  if (value == null) return fallback;
  if (value is bool) return value;
  return asInt(value) != 0;
}

bool? asBoolOrNull(Object? value) {
  if (value == null) return null;
  if (value is bool) return value;
  return asInt(value) != 0;
}

String asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

String? asStringOrNull(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  return value.toString();
}

int boolToInt(bool value) => value ? 1 : 0;

int? boolToIntOrNull(bool? value) => value == null ? null : (value ? 1 : 0);
