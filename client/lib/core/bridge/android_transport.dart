import 'package:flutter/services.dart';

/// Android 进程内通道。
///
/// Android 上没有 `Process.start`，core 通过 gomobile 打成 AAR，
/// 由 Kotlin 侧（`com.legado.legado.LegadoChannel`）把调用转给 Go 运行时。
/// 协议与 loopback HTTP 完全一致：传入/返回的都是信封 JSON 字符串，
/// 因此本类只负责传输，信封解析与错误映射留在 [LegadoClient]。
class AndroidTransport {
  static const MethodChannel channel = MethodChannel('legado/core');

  /// 初始化 Go 运行时。homeDir 由 Kotlin 侧取 `filesDir`，Dart 不传。
  Future<void> init({String version = ''}) async {
    await channel.invokeMethod<void>('init', <String, Object?>{
      'version': version,
    });
  }

  /// 发一次控制面调用，[request] 是完整请求信封 JSON，返回响应信封 JSON。
  Future<String> callRaw(String request) async {
    final resp = await channel.invokeMethod<String>('call', <String, Object?>{
      'request': request,
    });
    if (resp == null) {
      throw PlatformException(code: 'BAD_RESPONSE', message: 'core 返回空响应');
    }
    return resp;
  }

  /// 导出方法表 JSON（调试用）。
  Future<String?> methods() => channel.invokeMethod<String>('methods');
}
