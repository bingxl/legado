/// 搜索页与发现页共用的一套结果身份/分页合并规则。
library;

/// 单条结果的身份键：同书源下同一本书算重复。
/// 书源地址 + 书籍链接优先，链接缺失时退化成书名 + 作者。
String bookResultKey(Map<String, dynamic> item) {
  final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
  if (bookUrl.isNotEmpty) return '${item['origin'] ?? ''}|$bookUrl';
  return '${item['name'] ?? ''}|${item['author'] ?? ''}';
}

/// 把新一页结果并入已有列表（去重，保持首次出现顺序）。
/// 返回新列表；[incoming] 为空时原样返回 [current]，页面据此判断已到底。
List<Map<String, dynamic>> mergeBookResults(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) {
  if (incoming.isEmpty) return current;
  final seen = {for (final e in current) bookResultKey(e)};
  final out = List<Map<String, dynamic>>.of(current);
  for (final e in incoming) {
    if (seen.add(bookResultKey(e))) out.add(e);
  }
  return out;
}
