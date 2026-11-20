import 'dart:io';

import 'dart_js_engine.dart';
import 'js_engine.dart';
import 'quickjs_engine.dart';

/// 构造书源脚本引擎。
///
/// 默认用 QuickJS（真 JS 语义，漫画/加密书源那类脚本只有它能跑通）。
/// 纯 Dart 解释器保留为兜底，触发条件只有两个：
///
/// 1. 环境变量 `LEGADO_JS_ENGINE=dart`（排查两边语义差异时用）；
/// 2. QuickJS 的 native 库加载不起来 —— 例如没跑过 build hooks 的裸
///    `dart run`，或者不支持的平台。此时自动降级，书源至少还能跑简单脚本，
///    不会整条链路直接崩掉。
JsEngine createJsEngine({void Function(String level, String msg)? onLog}) {
  final preferred =
      Platform.environment['LEGADO_JS_ENGINE']?.trim().toLowerCase();
  if (preferred == 'dart' || preferred == 'interpreter') {
    return DartJsEngine(onLog: onLog);
  }
  return _QuickJsWithFallback(onLog: onLog);
}

class _QuickJsWithFallback implements JsEngine {
  _QuickJsWithFallback({this.onLog}) : _quickjs = QuickJsEngine(onLog: onLog);

  final void Function(String level, String msg)? onLog;
  QuickJsEngine? _quickjs;
  DartJsEngine? _dart;

  @override
  Future<Object?> eval(
    String script, {
    Map<String, Object?> bindings = const {},
  }) async {
    final quick = _quickjs;
    if (quick != null) {
      try {
        return await quick.eval(script, bindings: bindings);
      } on JsEngineUnavailable catch (e) {
        // 只在「引擎起不来」时降级；脚本自身报错（JsException）照常抛出。
        _quickjs = null;
        quick.dispose();
        onLog?.call('warn', 'QuickJS 不可用，回落到 Dart 解释器: ${e.message}');
      }
    }
    return (_dart ??= DartJsEngine(onLog: onLog)).eval(
      script,
      bindings: bindings,
    );
  }

  @override
  void dispose() {
    _quickjs?.dispose();
    _dart?.dispose();
    _quickjs = null;
    _dart = null;
  }
}
