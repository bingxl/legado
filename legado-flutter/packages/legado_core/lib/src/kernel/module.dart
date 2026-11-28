import 'dart:io';

import 'registry.dart';

/// 装配上下文：所有模块启动时能拿到的环境信息。
///
/// 刻意只放「与平台无关的字符串」：内核包不 import Flutter，
/// 拿不到 path_provider 之类的插件，数据目录由宿主（CLI 或 App）算好传进来。
class LegadoContext {
  const LegadoContext({
    required this.homeDir,
    required this.version,
    this.host = 'app',
  });

  /// 数据目录：数据库、缓存、下载都放它下面。
  final String homeDir;

  final String version;

  /// 运行形态：`cli` / `app` / `test`。
  ///
  /// 由宿主显式声明，不去猜可执行文件名 —— 猜错会在排查「CLI 行、App 不行」时
  /// 把人带到完全错误的方向（早先按 resolvedExecutable 猜，`dart run` 就被判成了 app）。
  final String host;

  String get platform => Platform.operatingSystem;

  String get arch {
    // Dart 没有直接给 CPU 架构的稳定 API；用解释器位数足够做诊断用途。
    return Platform.version.contains('arm64') ? 'arm64' : 'x64';
  }
}

/// 功能模块。
///
/// 对应旧 Go 内核的 `kernel.Module`：每个域自己声明依赖、自己建表、自己注册方法。
/// 宿主（CLI / Flutter）只负责挑模块列表，不认识任何具体方法名 ——
/// 这是「加一个域不用改宿主」的前提。
abstract class CoreModule {
  /// 模块名，同时是拓扑排序的节点标识。
  String get name;

  /// 依赖的模块名。Boot 会保证被依赖者先 migrate、先 register。
  List<String> get dependsOn => const [];

  /// 建表/迁移。启动时先全部跑完 migrate，再统一 register，
  /// 这样「A 的 service 在构造时就要读 B 的表」不会因为顺序踩空。
  Future<void> migrate(LegadoContext ctx) async {}

  /// 注册方法。
  void register(Registry registry, LegadoContext ctx);

  /// 全部模块注册完成后的启动钩子。
  ///
  /// 用于「依赖已齐、但不必等宿主调用任何方法」的初始化，
  /// 例如启动时清理过期缓存。抛异常会中断启动，内部要自己兜错。
  void onReady(LegadoContext ctx) {}

  /// 收尾：停后台任务、关连接池。
  Future<void> close() async {}
}
