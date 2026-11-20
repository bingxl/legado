import '../../store/database.dart';
import '../../store/store.dart';
import 'source_io.dart' show SourceGroupView;

/// 书源分组维护。
///
/// 分组是 `book_sources.bookSourceGroup` 里的逗号分隔字符串（`,` / `;` / `，` / `；`），
/// 没有独立的分组表。改分组时要重写整个字符串，但**其余分组必须原样保留**。
class SourceGroupService {
  SourceGroupService(this._daos);

  final StoreDaos _daos;

  /// 全部分组及其书源数量。
  ///
  /// 一条书源同时属于多个分组时，每个分组各计一次。
  List<SourceGroupView> listGroups() {
    final counts = <String, int>{};
    for (final source in _daos.bookSource.all) {
      for (final group in source.groups) {
        counts[group] = (counts[group] ?? 0) + 1;
      }
    }
    final names = counts.keys.toList()..sort();
    return [
      for (final name in names) SourceGroupView(name: name, count: counts[name]!),
    ];
  }

  /// 把分组 [from] 改名为 [to]，返回受影响的书源数。
  ///
  /// [to] 为空白等价于删除该分组（不会留下空分组名）。
  Future<int> rename(String from, String to) async {
    final source = from.trim();
    if (source.isEmpty) return 0;
    final target = to.trim();
    return _rewrite((groups) {
      if (!groups.contains(source)) return null;
      return [
        for (final group in groups)
          if (group == source) target else group,
      ];
    });
  }

  /// 从所有书源的分组串里摘掉 [group]，返回受影响的书源数。
  Future<int> remove(String group) async {
    final target = group.trim();
    if (target.isEmpty) return 0;
    return _rewrite((groups) {
      if (!groups.contains(target)) return null;
      return [
        for (final current in groups)
          if (current != target) current,
      ];
    });
  }

  /// 遍历全部书源改分组。
  ///
  /// 返回 null 表示该条不命中，避免把没变化的行也写一遍。
  /// 用 `upGroup` 而不是 `update`：只写一列，不会覆盖同一条书源的其它并发修改，
  /// 也不会触发 `INSERT OR REPLACE` 的级联删除。
  int _rewrite(List<String>? Function(List<String> groups) transform) {
    var affected = 0;
    runInTransaction(_daos.db, () {
      for (final source in _daos.bookSource.all) {
        final current = source.groups;
        final next = transform(current);
        if (next == null) continue;

        final normalized = <String>[];
        for (final group in next) {
          final trimmed = group.trim();
          if (trimmed.isNotEmpty && !normalized.contains(trimmed)) {
            normalized.add(trimmed);
          }
        }
        _daos.bookSource.upGroup(source.bookSourceUrl, normalized.join(','));
        affected++;
      }
    });
    return affected;
  }
}
