/// 设置存储的最小抽象。
///
/// 只做「键值对 + 批量写」，不关心底层是 sqlite 的 `app_settings` 表还是
/// 内存 Map：设置域的所有业务规则（默认值、区间钳制、枚举校验）都不该
/// 下沉到 DAO 里，否则换存储就要重写一遍校验。
///
/// DAO 由数据层实现本接口；本阶段只冻结方法签名，避免两个 agent 各写一套。
abstract interface class SettingsStorage {
  /// 全部已落库的键值（快照，调用方可以随意改）。
  Map<String, String> getAll();

  /// 单个键；不存在返回 null。
  String? get(String key);

  /// 批量写入。值为 null 表示删除该键（回到默认值）。
  Future<void> putAll(Map<String, String?> patch);

  /// 批量删除。不存在的键不报错。
  Future<void> removeAll(List<String> keys);
}
