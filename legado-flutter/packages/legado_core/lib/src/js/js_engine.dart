/// 书源脚本执行器接口。
///
/// 为什么先只定义接口、不急着定实现：书源里的 `<js>` / `@js:` 是这套系统里
/// 最大的不确定项。默认实现是纯 Dart 子集解释器（零 native、CLI 与 App 同一份语义），
/// 但如果真实书源的覆盖率不够，需要换成 FFI 嵌 QuickJS ——
/// 那时只替换本接口的实现类，规则层、服务层、UI 都不用动。
abstract interface class JsEngine {
  /// 执行一段脚本，返回结果（Dart 值：null/bool/num/String/List/Map）。
  ///
  /// [bindings] 是脚本可见的全局变量与函数，例如 `java`、`result`、`baseUrl`。
  /// 传函数进 bindings 就是桥接（`java.ajax` 这类）：宿主函数可以返回
  /// `Future`，引擎会在调用点等待它完成，脚本侧拿到的仍是最终结果。
  Future<Object?> eval(String script, {Map<String, Object?> bindings});

  /// 释放引擎持有的资源（FFI 实现必须实现它，否则会泄漏 native 句柄）。
  void dispose();
}

/// 引擎根本跑不起来（native 库没编出来、平台不支持等）。
///
/// 注意它和 [JsException] 的区别：这个是「换引擎」，后者是「脚本写错了」。
/// 上层（[createJsEngine]）只在收到本异常时才回落到纯 Dart 解释器。
class JsEngineUnavailable implements Exception {
  JsEngineUnavailable(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'JsEngineUnavailable: $message';
}
