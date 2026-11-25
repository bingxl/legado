import 'package:flutter/material.dart';

/// 轻量提示：替换掉 13 个页面里逐字相同的 `_toast` 方法体。
///
/// [mounted] 由调用方传入（State 里直接传 `mounted`），保证异步回调里
/// 页面已卸载时不会往死掉的 context 发 SnackBar。
/// [replace] 默认 true = 先隐藏上一条，避免批量操作时 SnackBar 排队。
void showAppToast(
  BuildContext context,
  String message, {
  bool mounted = true,
  bool replace = true,
  Duration? duration,
}) {
  if (!mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  if (replace) messenger.hideCurrentSnackBar();
  // 不传 duration 时沿用 SnackBar 默认值，保持与替换前一致。
  // SnackBar.duration 不可为 null，所以分两种构造。
  messenger.showSnackBar(
    duration == null
        ? SnackBar(content: Text(message))
        : SnackBar(content: Text(message), duration: duration),
  );
}
