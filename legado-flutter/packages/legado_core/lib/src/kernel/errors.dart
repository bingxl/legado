/// 控制面错误码。
///
/// 与旧 Go 内核的 code 取值完全一致：UI 层已经按这些字符串分支
/// （例如「书已被删」要退回书架，而不是弹重试），改名字会让调用方静默走错分支。
abstract final class ErrorCode {
  /// 目标不存在（书、章节、书源被删）。
  static const notFound = 'NOT_FOUND';

  /// 参数非法：类型不对、超出区间、缺少必填项。
  static const invalid = 'INVALID_ARGUMENT';

  /// 数据源为空或未配置（没有书源、未设置 WebDAV）。
  static const sourceEmpty = 'SOURCE_EMPTY';

  /// 网络超时/远端失败，可重试。
  static const netTimeout = 'NET_TIMEOUT';

  /// 需要登录态，或登录已失效。
  static const authRequired = 'AUTH_REQUIRED';

  /// 当前平台/构建不支持该能力（CLI 里的平台专属功能）。
  static const unsupported = 'UNSUPPORTED';

  /// 能力尚未实现。M0 阶段绝大多数方法都是这个码。
  static const notImplemented = 'NOT_IMPLEMENTED';

  /// 未预期的内部错误。调用方不该重试。
  static const internal = 'INTERNAL';
}

/// 内核统一异常。
///
/// 不用 `Exception` 的子类层级：调用方只需要 `code` 做分支，
/// 多一层类型只会让 CLI 与应用各写一套 match。
class LegadoException implements Exception {
  const LegadoException(this.code, this.message, {this.cause});

  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() => '$code: $message';
}
