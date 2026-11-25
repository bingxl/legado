import 'package:flutter/material.dart';

/// 图片验证码输入框，对齐原版 `VerificationCodeDialog`。
///
/// 书源里 `java.getVerificationCode(imageUrl)` 会阻塞在这上面：图片加载不出来
/// 就点「刷新」重试，用户取消返回 null（脚本侧会抛「验证码为空」）。
Future<String?> showCaptchaDialog(
  BuildContext context,
  Uri imageUri, {
  Map<String, String> headers = const {},
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _CaptchaDialog(imageUri: imageUri, headers: headers),
  );
}

class _CaptchaDialog extends StatefulWidget {
  const _CaptchaDialog({required this.imageUri, required this.headers});

  final Uri imageUri;
  final Map<String, String> headers;

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
  final TextEditingController _input = TextEditingController();

  /// 点「刷新」时改这个值，让 Image 重新发请求（同 URL 会有缓存）。
  int _nonce = 0;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('请输入验证码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _nonce++),
            child: Container(
              height: 64,
              alignment: Alignment.center,
              color: scheme.surfaceContainerHighest,
              child: Image.network(
                widget.imageUri.toString(),
                headers: widget.headers.isEmpty ? null : widget.headers,
                fit: BoxFit.contain,
                // gif 验证码是动的：不去缓存，每帧都要重新拉。
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.broken_image_outlined, color: scheme.error),
                    const SizedBox(width: 8),
                    const Text('图片加载失败，点击重试'),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '验证码',
              hintText: '看图输入，点图片可刷新',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_input.text.trim()),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
