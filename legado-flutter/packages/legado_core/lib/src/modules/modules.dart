import '../kernel/module.dart';
import 'system_module.dart';

/// 唯一的装配点。
///
/// 新增一个域只改这里：加一行模块实例，方法、CLI 命令、HTTP 路由都会自动出现。
/// 反过来说，任何宿主（Flutter / CLI / 未来的桌面壳）都**不允许**自己注册方法 ——
/// 一旦破坏这条，两个宿主的能力就会开始漂移。
List<CoreModule> buildModules() => [SystemModule()];
