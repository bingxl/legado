import 'package:legado_core/src/service/setting/settings_storage.dart';

/// 内存版 [SettingsStorage]，替代 sqlite 供设置域单测使用。
///
/// 设置域不碰数据库（那是数据层的事），这里也不需要真库：
/// 需要验证的是「默认值怎么合、非法值怎么处理」，存储只要行为正确即可。
class MemorySettingsStorage implements SettingsStorage {
  MemorySettingsStorage([Map<String, String>? initial])
    : _data = <String, String>{...?initial};

  final Map<String, String> _data;

  /// 落盘内容的只读快照，供断言「非法值没有被写进去」。
  Map<String, String> get snapshot => Map<String, String>.unmodifiable(_data);

  int putCalls = 0;
  int removeCalls = 0;

  @override
  Map<String, String> getAll() => Map<String, String>.from(_data);

  @override
  String? get(String key) => _data[key];

  @override
  Future<void> putAll(Map<String, String?> patch) async {
    putCalls++;
    patch.forEach((key, value) {
      if (value == null) {
        _data.remove(key);
      } else {
        _data[key] = value;
      }
    });
  }

  @override
  Future<void> removeAll(List<String> keys) async {
    removeCalls++;
    for (final key in keys) {
      _data.remove(key);
    }
  }
}
