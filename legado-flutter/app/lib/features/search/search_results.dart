/// 搜索结果的合并与分组。
library;

import '../../core/book_results.dart';

/// 与发现页共用同一套身份键规则（保留本页函数名，调用点无需改）。
String searchResultKey(Map<String, dynamic> item) => bookResultKey(item);

/// 与发现页共用同一套分页合并规则。
List<Map<String, dynamic>> mergeSearchResults(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) =>
    mergeBookResults(current, incoming);

/// 按原版 `SearchModel.mergeItems` 的规则合并搜索结果。
///
/// 三条口径都对齐原版：
/// 1. 同名同作者视为同一本书，来源累加到 `origins`（内存字段，不落库），
///    来源多的排在前面；
/// 2. 书名/作者与关键词**完全相等**的排在最前，其次**包含**关键词的，
///    最后才是其它结果（原版最后一组是「搜索词不在书名/作者里」的兜底）；
/// 3. 精确搜索开启时其它结果直接丢弃——与内核解析时的 filter 同一口径，
///    避免书源返回的不相关书混进列表。
///
/// 与 [mergeSearchResults] 的区别：那个是发现页用的分页去重，保持书源顺序；
/// 这里是搜索页按相关性重排，不能共用。
List<Map<String, dynamic>> mergeSearchResultsByRelevance(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming, {
  required String keyword,
  required bool precision,
}) {
  final key = keyword.trim();
  final accepted = precision
      ? incoming.where((item) => _containsKey(item, key)).toList()
      : incoming;
  if (current.isEmpty && accepted.isEmpty) return current;

  final buckets = <String, Map<String, dynamic>>{};
  final order = <String>[];
  void merge(Map<String, dynamic> item) {
    final identity = '${item['name'] ?? ''}\u0000${item['author'] ?? ''}';
    final existing = buckets[identity];
    if (existing == null) {
      final copy = Map<String, dynamic>.from(item);
      final origin = '${item['origin'] ?? ''}';
      copy['origins'] = <String>[if (origin.isNotEmpty) origin];
      buckets[identity] = copy;
      order.add(identity);
      return;
    }
    final origins = existing['origins'] as List<String>;
    final origin = '${item['origin'] ?? ''}';
    if (origin.isNotEmpty && !origins.contains(origin)) origins.add(origin);
  }

  for (final item in current) {
    merge(item);
  }
  for (final item in accepted) {
    merge(item);
  }

  final equal = <Map<String, dynamic>>[];
  final contains = <Map<String, dynamic>>[];
  final other = <Map<String, dynamic>>[];
  for (final identity in order) {
    final item = buckets[identity]!;
    if (_exactMatch(item, key)) {
      equal.add(item);
    } else if (_containsKey(item, key)) {
      contains.add(item);
    } else {
      other.add(item);
    }
  }

  return <Map<String, dynamic>>[
    ..._bySourceCount(equal),
    ..._bySourceCount(contains),
    if (!precision) ..._bySourceCount(other),
  ];
}

bool _exactMatch(Map<String, dynamic> item, String key) {
  if (key.isEmpty) return false;
  return '${item['name'] ?? ''}' == key || '${item['author'] ?? ''}' == key;
}

bool _containsKey(Map<String, dynamic> item, String key) {
  if (key.isEmpty) return true;
  return '${item['name'] ?? ''}'.contains(key) ||
      '${item['author'] ?? ''}'.contains(key);
}

/// 按来源数降序；数量相同保持原顺序（Dart 的 List.sort 不稳定，显式带下标）。
List<Map<String, dynamic>> _bySourceCount(List<Map<String, dynamic>> items) {
  final indexes = <int>[for (var i = 0; i < items.length; i++) i];
  indexes.sort((a, b) {
    final count = _sourceCount(items[b]).compareTo(_sourceCount(items[a]));
    return count != 0 ? count : a.compareTo(b);
  });
  return [for (final index in indexes) items[index]];
}

int _sourceCount(Map<String, dynamic> item) {
  final origins = item['origins'];
  if (origins is List) return origins.length;
  final origin = '${item['origin'] ?? ''}';
  return origin.isEmpty ? 0 : 1;
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
