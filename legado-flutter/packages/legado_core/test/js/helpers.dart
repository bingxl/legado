import 'dart:io';

import 'package:legado_core/src/js/dart_js_engine.dart';
import 'package:legado_core/src/js/js_engine.dart';
import 'package:legado_core/src/js/js_engine_factory.dart';
import 'package:legado_core/src/js/js_exception.dart';

/// 当前跑的是纯 Dart 解释器（`LEGADO_JS_ENGINE=dart`）。
///
/// 少数用例断言的是解释器的**值模型**（`undefined` 等价 `null`、字符串
/// 字面量 `instanceof String` 为真之类），真 JS 语义并不是那样。这些
/// 用例用 [dartOnly] 标出来：跑 QuickJS 时跳过，跑解释器时照常验证。
final bool dartEngine =
    Platform.environment['LEGADO_JS_ENGINE']?.trim().toLowerCase() == 'dart';

/// `skip:` 参数：只在 Dart 解释器下有意义。
String? get dartOnly => dartEngine ? null : 'Dart 解释器专有语义，真 JS 不同';

/// 测试统一入口：每次新建引擎，避免跨用例污染全局变量。
///
/// 走 [createJsEngine]，所以同一套用例默认跑 QuickJS；
/// `LEGADO_JS_ENGINE=dart` 时跑纯 Dart 解释器，用来对比两边语义。
JsEngine newEngine({void Function(String level, String msg)? onLog}) =>
    createJsEngine(onLog: onLog);

/// 明确指定纯 Dart 解释器（解释器自身的 parser / precompile / 报错文案）。
DartJsEngine newDartEngine({void Function(String level, String msg)? onLog}) =>
    DartJsEngine(onLog: onLog);

/// 用 Dart 解释器跑脚本并期望抛错（解释器专有的报错文案）。
Future<JsException> expectDartError(String script) async {
  final engine = newDartEngine();
  try {
    final v = await engine.eval(script);
    throw StateError('期望抛出 JsException，但返回了 $v');
  } on JsException catch (e) {
    return e;
  } finally {
    engine.dispose();
  }
}

Future<Object?> run(String script, {Map<String, Object?> bindings = const {}}) async {
  final engine = newEngine();
  try {
    return await engine.eval(script, bindings: bindings);
  } finally {
    engine.dispose();
  }
}

/// 期望抛出 [JsException]，并把信息交给断言。
Future<JsException> expectError(String script, {Map<String, Object?> bindings = const {}}) async {
  final engine = newEngine();
  try {
    final v = await engine.eval(script, bindings: bindings);
    throw StateError('期望抛出 JsException，但返回了 $v');
  } on JsException catch (e) {
    return e;
  } finally {
    engine.dispose();
  }
}
