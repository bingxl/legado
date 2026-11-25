import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 内置浏览器缺的那块平台能力：**读** cookie（含 HttpOnly）与 UA。
///
/// `webview_flutter` 只提供「写 cookie」（`WebViewCookieManager.setCookie`），
/// 而 Cloudflare 的 `cf_clearance` 是 HttpOnly —— 页面 JS 的 `document.cookie`
/// 读不到它。原版 legado 走的是 `android.webkit.CookieManager.getInstance()
/// .getCookie(url)`，这里通过宿主 MethodChannel 调同一个 API。
///
/// 没有通道的平台上（iOS / 桌面）退回 `document.cookie`：拿不到 HttpOnly 项，
/// 但验证页会把浏览器渲染的 HTML 一并交回，正文照样能出。
class WebViewBridge {
  WebViewBridge._();

  static const MethodChannel _channel = MethodChannel('flutter.legado/webview');

  /// 当前平台是否有内置浏览器（`webview_flutter` 只支持 Android / iOS）。
  static bool get supported => Platform.isAndroid || Platform.isIOS;

  /// 读一个地址在浏览器里的完整 cookie 串；读不到返回 null。
  static Future<String?> cookies(WebViewController controller, Uri uri) async {
    if (Platform.isAndroid) {
      try {
        final value = await _channel.invokeMethod<String>('cookies', {
          'url': uri.toString(),
        });
        if (value != null && value.isNotEmpty) return value;
      } on PlatformException {
        // 通道不可用（宿主没注册）：退回 JS，少 HttpOnly 也比完全没有强。
      } on MissingPluginException {
        // 热重载/测试环境。
      }
    }
    return _eval(controller, 'document.cookie');
  }

  /// 浏览器真实 UA。`cf_clearance` 与 UA 绑定，回填内核时必须是这一个。
  static Future<String?> userAgent(WebViewController controller) async {
    if (Platform.isAndroid) {
      try {
        final value = await _channel.invokeMethod<String>('userAgent');
        if (value != null && value.isNotEmpty) return value;
      } on PlatformException {
        // 同上。
      } on MissingPluginException {
        // 同上。
      }
    }
    return _eval(controller, 'navigator.userAgent');
  }

  /// 当前页面的 `outerHTML`（原版 `saveVerificationResult` 的 `refetchAfterSuccess=false` 分支）。
  static Future<String?> html(WebViewController controller) =>
      _eval(controller, 'document.documentElement.outerHTML');

  static Future<String?> _eval(
    WebViewController controller,
    String script,
  ) async {
    try {
      return jsStringValue(await controller.runJavaScriptReturningResult(script));
    } catch (_) {
      // 页面还在导航、被销毁、或脚本报错：当作读不到，由调用方兜底。
      return null;
    }
  }
}

/// 把 `runJavaScriptReturningResult` 的结果归一成 Dart 字符串。
///
/// Android 返回的是**JSON 编码**的字面量：字符串带引号、换行写成 `\n`；
/// iOS 直接给 Dart 字符串。不归一的话 `outerHTML` 会带着一层引号进正文，
/// 后续规则一律解析不到正文。
String? jsStringValue(Object? value) {
  if (value == null) return null;
  if (value is! String) return '$value';
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is String) return decoded;
    } catch (_) {
      // 不是合法 JSON（含裸引号的普通文本），按原样去掉首尾引号。
    }
    return value.substring(1, value.length - 1);
  }
  return value;
}

/// 把 JS 布尔结果归一。
///
/// Android 走 JSON：`true` / `false`；iOS 与部分机型给字符串 `"true"`。
/// Cloudflare 挑战判定就靠这个值，归一错了表现为「验证页一直不自动完成」。
bool jsBooleanValue(Object? value) {
  if (value is bool) return value;
  final text = (jsStringValue(value) ?? '').trim().toLowerCase();
  return text == 'true' || text == '1';
}
