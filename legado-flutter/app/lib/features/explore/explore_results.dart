/// 发现页结果的分页合并。
///
/// 书源的分页并不总是稳定（有的源末页会重复返回上一页内容），直接 append
/// 会出现重复卡片；这里按「来源 + 书籍链接」去重，链接缺失时退化用「书名 + 作者」。
library;

import '../../core/book_results.dart';

/// 与搜索页共用同一套身份键规则（保留本页函数名，调用点无需改）。
String exploreResultKey(Map<String, dynamic> item) => bookResultKey(item);

/// 与搜索页共用同一套分页合并规则。
List<Map<String, dynamic>> mergeResults(
  List<Map<String, dynamic>> current,
  List<Map<String, dynamic>> incoming,
) =>
    mergeBookResults(current, incoming);
