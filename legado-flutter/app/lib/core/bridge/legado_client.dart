import 'dart:io';

import 'package:legado_core/legado_core.dart';
import 'package:path_provider/path_provider.dart';

/// 桥接层错误。code 与内核错误码一致（NOT_FOUND / INVALID_ARGUMENT …）。
///
/// 名字保留 `LegadoError` 而不是直接用 [LegadoException]：UI 的 19 个页面都按
/// 这个名字做 catch，改名会把错误处理全部打断，而这层薄包装没有信息损失。
class LegadoError implements Exception {
  const LegadoError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 应用侧的内核入口。
///
/// 曾经这里是一个 HTTP 客户端 + 子进程管理器（Go core 独立进程 / gomobile AAR）。
/// 内核改成纯 Dart 后，唯一要做的事变成「算好数据目录，把内核叫起来」；
/// 调用直接落到同一进程里的 [LegadoCore]，没有序列化、没有端口、没有生命周期竞态。
///
/// 保留这个类（而不是让页面直接调 [LegadoCore]）有两个理由：
/// 1. 25 处调用点依赖 `LegadoClient.instance.call` 的签名；
/// 2. 数据目录与版本号属于宿主知识，不该泄漏进内核。
class LegadoClient {
  LegadoClient._(this.homeDir);

  static LegadoClient? _instance;

  static LegadoClient get instance {
    final c = _instance;
    if (c == null) {
      throw StateError('bridge 尚未初始化，请先 await LegadoClient.connect()');
    }
    return c;
  }

  static bool get isReady => _instance != null;

  /// 数据目录：数据库、缓存、下载都在它下面。
  final String homeDir;

  /// 启动内核。重复调用是幂等的。
  static Future<LegadoClient> connect() async {
    final existing = _instance;
    if (existing != null) return existing;

    final home = await _resolveHome();
    await LegadoCore.instance.init(homeDir: home, version: _version());

    final client = LegadoClient._(home);
    _instance = client;
    return client;
  }

  /// 调用内核方法。参数是**位置参数**，顺序与 `legado methods` 里的签名一致。
  Future<dynamic> call(String method, [List<Object?> args = const []]) async {
    try {
      return await LegadoCore.instance.call(method, args);
    } on LegadoException catch (e) {
      throw LegadoError(e.code, e.message);
    }
  }

  /// 便捷：把结果当 `List<Map>` 使用。
  Future<List<Map<String, dynamic>>> callList(
    String method, [
    List<Object?> args = const [],
  ]) async {
    final data = await call(method, args);
    if (data == null) return const [];
    return (data as List).cast<Map<String, dynamic>>();
  }

  Future<void> dispose() async {
    await LegadoCore.instance.close();
    _instance = null;
  }

  /// 数据目录优先级：`--dart-define=LEGADO_HOME` > 环境变量 > 应用私有目录。
  ///
  /// 前两条是给开发者与 CI 用的（同一份数据跑两种形态）；正常安装时走第三条，
  /// 避免在 Android 上因为写不了外部目录而崩在启动阶段。
  static Future<String> _resolveHome() async {
    const defined = String.fromEnvironment('LEGADO_HOME');
    if (defined.isNotEmpty) return defined;

    final env = Platform.environment['LEGADO_HOME'];
    if (env != null && env.isNotEmpty) return env;

    try {
      final dir = await getApplicationSupportDirectory();
      return dir.path;
    } catch (_) {
      // 插件不可用（纯 Dart 测试、未注册的平台）时退回用户目录，
      // 保证 connect 不会因为「拿不到目录」直接失败。
      final userHome =
          Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
      return '${userHome ?? '.'}${Platform.pathSeparator}.legado';
    }
  }

  static String _version() {
    const defined = String.fromEnvironment('LEGADO_VERSION');
    return defined.isEmpty ? 'dev' : defined;
  }
}
