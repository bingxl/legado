import 'ast.dart';
import 'js_engine.dart';
import 'js_exception.dart';
import 'parser.dart';
import 'values.dart';
import 'interpreter.dart';

/// 纯 Dart 的书源脚本引擎。
///
/// - 不依赖任何 native 库，CLI 与 App 跑同一份语义；
/// - 同一段脚本重复执行会命中 AST 缓存（书源详情页一次要跑几十个脚本）；
/// - 宿主函数可以返回 `Future`：解释器会在调用点 await 掉，
///   所以书源里 `java.ajax(url)` 拿到的仍然是响应文本。
class DartJsEngine implements JsEngine {
  DartJsEngine({this.onLog});

  /// console.log / java.log 的输出通道。默认丢弃（避免污染 CLI stdout），
  /// 上层接 `logging` 包的 logger 即可。
  final void Function(String level, String msg)? onLog;

  final Map<String, Program> _cache = <String, Program>{};

  @override
  Future<Object?> eval(String script, {Map<String, Object?> bindings = const {}}) async {
    Program program;
    try {
      program = _parse(script);
    } on JsException catch (e) {
      throw _withScript(e, script);
    }

    final interp = Interpreter(onLog: onLog, script: script);
    try {
      final result = await interp.run(program, bindings);
      return normalizeResult(result);
    } on JsException catch (e) {
      throw _withScript(e, script);
    } on StackOverflowError {
      // 解释器是递归下降求值，脚本递归太深会真的把 Dart 栈打穿。
      throw JsException('脚本递归过深（栈溢出）', script: script);
    }
  }

  /// 预编译：书源里同一段 `@js:` 会在列表页反复执行，提前解析能省掉重复成本。
  void precompile(String script) {
    _parse(script);
  }

  @override
  void dispose() {
    _cache.clear();
  }

  Program _parse(String script) {
    final cached = _cache[script];
    if (cached != null) return cached;
    final program = Parser(script).parseProgram();
    _cache[script] = program;
    return program;
  }

  JsException _withScript(JsException e, String script) {
    final line = e.line;
    return e.withLocation(
      script: script,
      sourceLine: e.sourceLine ?? (line == null ? null : sourceLineOf(script, line)),
    );
  }
}

/// 把解释器内部值收敛成接口约定的 Dart 值（null/bool/num/String/List/Map）。
Object? normalizeResult(Object? v) {
  if (v == null || v is bool || v is num || v is String) return v;
  if (v is JsDate) return v.millisecondsSinceEpoch;
  if (v is JsRegExp) return v.toString();
  if (v is JsArray) {
    return <Object?>[for (final e in v) normalizeResult(e)];
  }
  if (v is List) {
    return <Object?>[for (final e in v) normalizeResult(e)];
  }
  if (v is Map) {
    final out = <String, Object?>{};
    v.forEach((k, val) => out['$k'] = normalizeResult(val));
    return out;
  }
  if (v is JsHostObject) {
    final out = <String, Object?>{};
    for (final k in v.ownKeys()) {
      out[k] = normalizeResult(v.getProperty(k));
    }
    return out;
  }
  if (v is JsCallable) return null;
  return v;
}
