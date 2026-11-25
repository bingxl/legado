import 'package:flutter/material.dart';
import 'package:legado_core/legado_core.dart';

import '../../features/webview/captcha_dialog.dart';
import '../../features/webview/verification_page.dart';
import '../webview/webview_bridge.dart';

/// 把 App 的「内置浏览器」注册进内核。
///
/// 内核侧只认两个函数指针（[HostVerification]）：网络层撞到
/// `cf-mitigated: challenge` 时调浏览器回调，`java.getVerificationCode` 调
/// 验证码回调。注册一次，之后所有 `NetClient`（书源 / RSS / 登录）都自动生效。
class VerificationHost {
  VerificationHost._();

  static void install(GlobalKey<NavigatorState> navigatorKey) {
    HostVerification.register((request) async {
      if (!WebViewBridge.supported) {
        throw const LegadoException(
          ErrorCode.unsupported,
          '当前平台不支持内置浏览器验证，请在手机上打开本站完成一次验证',
        );
      }
      final navigator = navigatorKey.currentState;
      if (navigator == null) {
        throw const LegadoException(ErrorCode.internal, '界面尚未就绪，无法打开验证窗口');
      }
      return navigator.push<BrowserVerificationResult>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => VerificationPage(request: request),
        ),
      );
    });

    HostVerification.registerCaptcha((imageUri) async {
      final context = navigatorKey.currentContext;
      if (context == null) return null;
      return showCaptchaDialog(context, imageUri);
    });
  }

  /// 注销（测试与热重载用）。
  static void dispose() {
    HostVerification.register(null);
    HostVerification.registerCaptcha(null);
  }
}
