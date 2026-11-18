/// 详情页的目录预览工具。
library;

/// 只取目录前 [limit] 章。
///
/// 网络书目录可能上千章，详情页首屏全部渲染会明显卡顿；
/// 完整目录放在「全部章节」底部弹层里按需构建。
List<Map<String, dynamic>> previewChapters(
  List<Map<String, dynamic>> chapters, {
  int limit = 20,
}) {
  if (limit <= 0) return const [];
  if (chapters.length <= limit) return List<Map<String, dynamic>>.of(chapters);
  return chapters.sublist(0, limit);
}
