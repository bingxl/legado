import 'dart:convert';

import 'errors.dart';
import 'registry.dart';

/// 请求/响应信封。
///
/// UI 走进程内调用不需要序列化，但 CLI、HTTP 数据面、以及「把一次失败复现出来」
/// 都需要一个稳定的文本格式。所以信封只在这一层出现，不影响 UI。
class Envelope {
  Envelope._();

  /// 处理一条 JSON 请求，返回 JSON 响应。
  ///
  /// 无论 handler 抛什么，都必须返回合法信封：CLI 与 HTTP 靠它区分成败，
  /// 直接抛出去会让调用方拿到 500 而不是可读的 code。
  static Future<String> handle(Registry registry, String raw) async {
    Object? id;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return _error(null, ErrorCode.invalid, '请求必须是 JSON 对象');
      }
      id = decoded['id'];
      final method = decoded['method'];
      if (method is! String || method.trim().isEmpty) {
        return _error(id, ErrorCode.invalid, '缺少 method');
      }
      final args = decoded['args'];
      final list = switch (args) {
        null => const <Object?>[],
        List() => args.cast<Object?>(),
        _ => throw const LegadoException(ErrorCode.invalid, 'args 必须是数组'),
      };
      final data = await registry.invoke(method, list);
      return jsonEncode({'id': id, 'ok': true, 'data': data});
    } on LegadoException catch (e) {
      return _error(id, e.code, e.message);
    } on FormatException catch (e) {
      return _error(id, ErrorCode.invalid, '请求不是合法 JSON: ${e.message}');
    } catch (e) {
      return _error(id, ErrorCode.internal, '$e');
    }
  }

  static String _error(Object? id, String code, String msg) =>
      jsonEncode({
        'id': id,
        'ok': false,
        'err': {'code': code, 'msg': msg},
      });
}
