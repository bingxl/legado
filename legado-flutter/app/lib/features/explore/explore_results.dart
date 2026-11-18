/// 发现页结果的分页合并。
///
/// 书源的分页并不总是稳定（有的源末页会重复返回上一页内容），直接 append
/// 会出现重复卡片；这里按「来源 + 书籍链接」去重，链接缺失时退化用「书名 + 作者」。
library;

/// 单条发现结果的身份键。
///
/// origin 是书源地址，同一本书可能被多个源搜到，所以必须和书源一起构成键。
String exploreResultKey(Map<String, dynamic> item) {
  final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
  if (bookUrl.isNotEmpty) return '${item['origin'] ?? ''}|$bookUrl';
  return '${item['name'] ?? ''}|${item['author'] ?? ''}';
}

/// 把新一页结果并入已有列表。
///
/// 返回新列表，不修改入参；[incoming] 为空时原样返回 [current]，
/// 页面据「本页是否为空」判断已经到底。
List<Map<String, dynamic>> mergeResults(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) {
  if (incoming.isEmpty) return current;
  final seen = {for (final e in current) exploreResultKey(e)};
  final out = List<Map<String, dynamic>>.of(current);
  for (final e in incoming) {
    if (seen.add(exploreResultKey(e))) out.add(e);
  }
  return out;
}
