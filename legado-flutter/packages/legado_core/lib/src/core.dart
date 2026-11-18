import 'kernel/envelope.dart';
import 'kernel/errors.dart';
import 'kernel/module.dart';
import 'kernel/registry.dart';
import 'modules/modules.dart';

/// 内核唯一入口。
///
/// 双端共用：Flutter 进程内直接 `call`，CLI 通过 `handle` 收发 JSON 信封。
/// 两条路径最终都落到同一个 [Registry]，所以「CLI 能跑的功能，App 一定也有」。
class LegadoCore {
  LegadoCore._();

  static final LegadoCore instance = LegadoCore._();

  /// 方法表。暴露出来是为了让 `check-methods` 与调试工具能读到完整签名。
  final Registry registry = Registry();

  final List<CoreModule> _modules = [];
  LegadoContext? _ctx;
  bool _ready = false;

  bool get isReady => _ready;

  LegadoContext get context {
    final ctx = _ctx;
    if (ctx == null) {
      throw StateError('内核尚未初始化，请先 await LegadoCore.instance.init(...)');
    }
    return ctx;
  }

  /// 初始化。重复调用是幂等的（热重载、路由重建都会重复走到这里）。
  Future<void> init({
    required String homeDir,
    String version = 'dev',
    String host = 'app',
  }) async {
    if (_ready) return;

    final ctx = LegadoContext(homeDir: homeDir, version: version, host: host);
    _ctx = ctx;

    final modules = buildModules();
    _modules
      ..clear()
      ..addAll(_topoSort(modules));

    // 先全量 migrate 再全量 register：模块之间可以放心在 service 构造时读别人的表。
    for (final m in _modules) {
      await m.migrate(ctx);
    }
    for (final m in _modules) {
      m.register(registry, ctx);
    }
    _ready = true;
  }

  /// 进程内调用。参数是位置参数，与 [Registry] 的 `params` 声明顺序一致。
  Future<Object?> call(String method, [List<Object?> args = const []]) {
    if (!_ready) {
      throw const LegadoException(
        ErrorCode.internal,
        '内核尚未初始化',
      );
    }
    return registry.invoke(method, args);
  }

  /// 处理 JSON 信封（CLI / HTTP 用）。
  Future<String> handle(String raw) => Envelope.handle(registry, raw);

  /// 方法表，可按域过滤。
  List<MethodDef> methods([String? domain]) {
    final all = registry.all;
    if (domain == null || domain.isEmpty) return all;
    final prefix = '$domain.';
    return all.where((m) => m.name.startsWith(prefix)).toList();
  }

  Future<void> close() async {
    for (final m in _modules.reversed) {
      await m.close();
    }
    _modules.clear();
    // 注册表也要清：单例会被「关闭 → 重新 init」复用，留着旧方法会让
    // 第二轮注册直接抛「方法重复注册」。
    registry.clear();
    _ready = false;
    _ctx = null;
  }

  /// 拓扑排序：被依赖者在前。
  ///
  /// 手写而不是引第三方包：模块数很少，且这里更需要「出错时给出可读的环路径」，
  /// 而不是一个泛化的排序库。
  static List<CoreModule> _topoSort(List<CoreModule> modules) {
    final byName = {for (final m in modules) m.name: m};
    final ordered = <CoreModule>[];
    final state = <String, int>{}; // 0 未访问 / 1 访问中 / 2 已完成

    void visit(String name, List<String> path) {
      final s = state[name] ?? 0;
      if (s == 2) return;
      if (s == 1) {
        throw StateError('模块依赖成环: ${[...path, name].join(' -> ')}');
      }
      final module = byName[name];
      if (module == null) {
        throw StateError('缺少依赖模块: $name（被 ${path.isEmpty ? '根' : path.last} 引用）');
      }
      state[name] = 1;
      for (final dep in module.dependsOn) {
        visit(dep, [...path, name]);
      }
      state[name] = 2;
      ordered.add(module);
    }

    for (final m in modules) {
      visit(m.name, const []);
    }
    return ordered;
  }
}
