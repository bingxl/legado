import 'dart:io';

import '../kernel/module.dart';
import '../kernel/registry.dart';

/// 系统域：唯一一个不依赖数据库的模块，也是最早能用来验证链路是否通的域。
///
/// `System.Methods` 是这套架构的「功能清单」：CLI 的 `methods`、并行开发时的
/// 契约核对、以及「某个域到底注册了什么」都从它读，不再靠 grep 源码。
class SystemModule extends CoreModule {
  @override
  String get name => 'system';

  @override
  void register(Registry registry, LegadoContext ctx) {
    registry.method(
      'System.Info',
      (args) async => {
        'platform': ctx.platform,
        'arch': ctx.arch,
        'version': ctx.version,
        'runtime': 'dart ${Platform.version.split(' ').first}',
        'home': ctx.homeDir,
        // 标记运行形态，便于排查「同样的代码 CLI 行、App 不行」这类问题。
        'host': ctx.host,
      },
      doc: '版本与运行环境',
    );

    registry.method(
      'System.Methods',
      (args) async => registry.all.map((m) => m.describe()).toList(),
      doc: '已注册的方法表',
    );

    registry.method(
      'System.Echo',
      (args) async => args,
      params: const ['value any'],
      doc: '原样返回，供连通性自检',
    );
  }
}
