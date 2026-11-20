import '../../store/dao/settings_dao.dart';
import 'settings_storage.dart';

/// [SettingsStorage] 的 sqlite 实现。
///
/// 只是一个薄适配：设置域不该知道表名与 SQL，数据层也不该知道
/// 「未知 key 忽略、越界钳制」这些业务规则。两层之间就靠这个接口隔开，
/// 换存储（测试用内存版、将来换 pref 文件）时业务代码一行不动。
///
/// 不用 `SettingsDao implements SettingsStorage`：那会让 `store → service`
/// 反向依赖，数据层从此认识业务接口，`store` 的测试也会被 service 里的
/// 类型拽进编译面。
class DaoSettingsStorage implements SettingsStorage {
  DaoSettingsStorage(this._dao);

  final SettingsDao _dao;

  @override
  Map<String, String> getAll() => _dao.getAll();

  @override
  String? get(String key) => _dao.get(key);

  @override
  Future<void> putAll(Map<String, String?> patch) => _dao.putAll(patch);

  @override
  Future<void> removeAll(List<String> keys) => _dao.removeAll(keys);
}
