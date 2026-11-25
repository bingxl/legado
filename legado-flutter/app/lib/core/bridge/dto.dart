// 内核返回的是动态 JSON，各 API 包装层都需要同样的安全转换。
// 集中在这里，避免每个 feature 各写一份。

Map<String, dynamic> asStringMap(dynamic data) {
  if (data is Map) return data.cast<String, dynamic>();
  return <String, dynamic>{};
}

/// 后端可能给 int / double / 字符串，缺失时为 0。
int asInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String asStr(dynamic value) => value == null ? '' : '$value';
