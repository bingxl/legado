/// 搜索结果的合并与分组。
library;

/// 单条搜索结果的身份键：同书源下同一本书算重复。
String searchResultKey(Map<String, dynamic> item) {
  final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
  if (bookUrl.isNotEmpty) return '${item['origin'] ?? ''}|$bookUrl';
  return '${item['name'] ?? ''}|${item['author'] ?? ''}';
}

/// 把新一页结果并入已有列表（去重，保持顺序）。
List<Map<String, dynamic>> mergeSearchResults(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) {
  if (incoming.isEmpty) return current;
  final seen = {for (final e in current) searchResultKey(e)};
  final out = List<Map<String, dynamic>>.of(current);
  for (final e in incoming) {
    if (seen.add(searchResultKey(e))) out.add(e);
  }
  return out;
}

/// 按来源书源聚合的结果分组。
class SearchGroup {
  SearchGroup({required this.name, required this.items});

  /// 展示用的书源名（originName 缺失时回退 origin 地址）。
  final String name;
  final List<Map<String, dynamic>> items;
}

/// 按来源分组，保持首次出现的顺序。
///
/// `SearchAll` 是逐个书源串行追加的，所以顺序天然是书源顺序；
/// 这里用 LinkedHashMap 的插入序把它固化成展示顺序。
List<SearchGroup> groupBySource(List<Map<String, dynamic>> items) {
  final order = <String>[];
  final buckets = <String, List<Map<String, dynamic>>>{};
  for (final item in items) {
    final name = _sourceName(item);
    final bucket = buckets[name];
    if (bucket == null) {
      order.add(name);
      buckets[name] = <Map<String, dynamic>>[item];
    } else {
      bucket.add(item);
    }
  }
  return [
    for (final name in order) SearchGroup(name: name, items: buckets[name]!),
  ];
}

String _sourceName(Map<String, dynamic> item) {
  final originName = '${item['originName'] ?? ''}'.trim();
  if (originName.isNotEmpty) return originName;
  final origin = '${item['origin'] ?? ''}'.trim();
  return origin.isEmpty ? '未知书源' : origin;
}
