/// 注册表 handler 的参数收敛工具。
///
/// 信封里的数字可能是 `int` / `double`，bool 偶尔是 `1` / `"true"`；
/// 各模块自己抄一份会在边界上慢慢分叉（比如 A 接受 `"1"`、B 不接受），
/// 所以统一放这里。模块只把收好的强类型交给 service。
library;

import '../kernel/errors.dart';

Object? arg(List<Object?> args, int index) =>
    index < args.length ? args[index] : null;

int asInt(Object? raw) {
  if (raw == null) return 0;
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.toInt() : 0;
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  throw LegadoException(ErrorCode.invalid, '需要整数，收到 ${raw.runtimeType}');
}

double asDouble(Object? raw) {
  if (raw == null) return 0;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim()) ?? 0;
  throw LegadoException(ErrorCode.invalid, '需要数字，收到 ${raw.runtimeType}');
}

String asText(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw;
  if (raw is num || raw is bool) return '$raw';
  throw LegadoException(ErrorCode.invalid, '需要字符串，收到 ${raw.runtimeType}');
}

/// 批量操作的 ID 列表：跨宿主信封里可能是 `int` / `double` / 数字字符串。
List<int> asIntList(Object? raw) {
  if (raw == null) return const <int>[];
  if (raw is! List) {
    throw LegadoException(ErrorCode.invalid, '需要整数数组，收到 ${raw.runtimeType}');
  }
  return [for (final item in raw) asInt(item)];
}

bool asBool(Object? raw) {
  if (raw == null) return false;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    return switch (raw.toLowerCase()) {
      'true' || '1' || 'yes' => true,
      _ => false,
    };
  }
  throw LegadoException(ErrorCode.invalid, '需要布尔值，收到 ${raw.runtimeType}');
}

/// UI 有时把 Map 参数塞成 JSON 字符串（跨宿主信封转换的中间态）。
Map<String, Object?> asMap(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is Map) return raw.cast<String, Object?>();
  throw LegadoException(ErrorCode.invalid, '需要对象，收到 ${raw.runtimeType}');
}
