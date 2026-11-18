import 'errors.dart';

/// 方法处理函数。参数是**位置参数**：UI 与 CLI 传的都是 JSON 数组，
/// Dart 反射拿不到参数名，用命名参数只会让两侧各维护一份映射。
typedef MethodHandler = Future<Object?> Function(List<Object?> args);

/// 一个可调用方法的自描述。
///
/// `params` 不是给人看的注释，而是契约：CLI 的 `legado methods` 导出它，
/// 并行开发时各模块靠它对齐参数顺序；`check-methods` 也按它核对调用点。
class MethodDef {
  const MethodDef({
    required this.name,
    required this.handler,
    this.params = const [],
    this.doc = '',
    this.streaming = false,
  });

  /// 全名，形如 `Shelf.ListBooks`。域名与方法名用点分隔，第一段即域。
  final String name;

  final MethodHandler handler;

  /// 参数说明，每项形如一 `bookId int` 或 `onlyUnread bool`（带类型便于生成 SDK）。
  final List<String> params;

  final String doc;

  /// 是否返回事件流（书源调试、缓存进度）。CLI 下会改成逐行输出。
  final bool streaming;

  String get domain => name.split('.').first;

  String get verb => name.split('.').skip(1).join('.');

  Map<String, Object?> describe() => {
    'name': name,
    'domain': domain,
    'params': params,
    'doc': doc,
    if (streaming) 'streaming': true,
  };
}

/// 方法注册表。
///
/// 取代旧 Go 内核的反射注册：Dart 没有运行期反射，
/// 所以每个域在自己的 `register()` 里显式 `add`，由 `LegadoCore.init` 统一装配。
/// 显式注册的代价是要多写几行，好处是 `dart analyze` 能检查、调用点可跳转、
/// 也不会有「方法名拼对但没注册」的隐性失败。
class Registry {
  final Map<String, MethodDef> _methods = {};

  /// 已注册方法（按名字排序，保证 `methods` 输出稳定，方便 diff）。
  List<MethodDef> get all {
    final list = _methods.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return List.unmodifiable(list);
  }

  MethodDef? lookup(String name) => _methods[name];

  void add(MethodDef def) {
    final existing = _methods[def.name];
    if (existing != null) {
      throw StateError('方法重复注册: ${def.name}');
    }
    _methods[def.name] = def;
  }

  /// 清空注册表。
  ///
  /// 必须有：内核可以被 close 后重新 init（测试复用单例、Flutter 热重启），
  /// 不清理的话第二次注册会撞「方法重复注册」，而那个错看起来像是模块写错了。
  void clear() => _methods.clear();

  /// 便捷注册，省掉 `MethodDef(...)` 的样板。
  void method(
    String name,
    MethodHandler handler, {
    List<String> params = const [],
    String doc = '',
    bool streaming = false,
  }) {
    add(
      MethodDef(
        name: name,
        handler: handler,
        params: params,
        doc: doc,
        streaming: streaming,
      ),
    );
  }

  /// 调用一个方法。
  ///
  /// 这里集中做三件调用方不该重复的事：
  /// 1. 未注册 → NOT_FOUND（而不是空指针）；
  /// 2. 参数类型/个数不对 → INVALID_ARGUMENT（Dart 的 TypeError 会逃到 UI，
  ///    表现为「崩溃」而不是「提示参数错」，这类反馈最难定位）；
  /// 3. 任何非 [LegadoException] 的异常 → INTERNAL，并保留原始错误。
  Future<Object?> invoke(String name, List<Object?> args) async {
    final def = _methods[name];
    if (def == null) {
      throw LegadoException(ErrorCode.notFound, '方法不存在: $name');
    }
    try {
      return await def.handler(args);
    } on LegadoException {
      rethrow;
    } on TypeError catch (e) {
      throw LegadoException(ErrorCode.invalid, '参数类型不匹配: $e', cause: e);
    } on RangeError catch (e) {
      throw LegadoException(ErrorCode.invalid, '参数个数或下标越界: $e', cause: e);
    } on FormatException catch (e) {
      throw LegadoException(ErrorCode.invalid, '参数格式错误: ${e.message}', cause: e);
    } catch (e) {
      throw LegadoException(ErrorCode.internal, '$e', cause: e);
    }
  }
}
