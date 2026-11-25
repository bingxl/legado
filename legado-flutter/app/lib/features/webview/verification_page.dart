import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:legado_core/legado_core.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/webview/webview_bridge.dart';

/// 内置浏览器验证页。
///
/// 对齐原版 `WebViewActivity` + `WebViewModel.saveVerificationResult`：
/// - 用被拦截请求的请求头加载页面（换了头很多站点直接 403）；
/// - 每加载完一页就把浏览器 cookie 回填内核（`Source.ImportCookie`），
///   这样「开个窗让用户登录」的场景关掉窗口也不会丢登录态；
/// - 用 `!!window._cf_chl_opt` 判断当前是不是 Cloudflare 挑战页，
///   **挑战过完之后**自动收尾（原版就是这个行为）；
/// - 用户点「完成」时把 `outerHTML` + cookie + UA 一起交回内核。
class VerificationPage extends StatefulWidget {
  const VerificationPage({super.key, required this.request});

  final BrowserVerificationRequest request;

  @override
  State<VerificationPage> createState() => _VerificationPageState();
}

class _VerificationPageState extends State<VerificationPage> {
  late final WebViewController _controller;

  int _progress = 0;
  String _url = '';

  /// 见过挑战页。Cloudflare 的流程是「挑战页 → 通过后跳真实页」，
  /// 只有先见过挑战、再落到非挑战页，才算真的过了。
  bool _sawChallenge = false;
  bool _solved = false;

  /// 收尾只能走一次：`onPageFinished` 会连续触发，重复 pop 会把上一页也弹掉。
  bool _finishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _url = widget.request.uri.toString();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (url) {
            if (mounted) setState(() => _url = url);
          },
          onPageFinished: (url) => _afterPageLoaded(url),
          onWebResourceError: (error) {
            // 子资源（图片/脚本）失败很常见，只有主文档失败才算页面错误。
            if (error.isForMainFrame != true) return;
            if (mounted) setState(() => _error = error.description);
          },
        ),
      );
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    await _controller.loadRequest(
      widget.request.uri,
      // 空 map 是允许的：浏览器会用默认头。
      headers: widget.request.headers,
    );
  }

  /// 每完成一次主文档加载：回填 cookie → 判定挑战是否已过。
  Future<void> _afterPageLoaded(String url) async {
    if (_finishing || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final cookie = await WebViewBridge.cookies(_controller, uri);
    final userAgent = await WebViewBridge.userAgent(_controller);
    if (cookie != null && cookie.trim().isNotEmpty) {
      await _pushCookie(uri, cookie, userAgent);
    }
    if (!mounted || _finishing) return;

    final challenge = await _isChallengePage();
    if (!mounted || _finishing) return;

    if (challenge) {
      if (!_sawChallenge) setState(() => _sawChallenge = true);
      return;
    }
    // 挑战页过完落到真实页面：原版在这里直接保存结果并退出。
    if (_sawChallenge && !_solved) {
      setState(() => _solved = true);
      await _finish();
    }
  }

  Future<bool> _isChallengePage() async {
    try {
      final value = await _controller.runJavaScriptReturningResult(
        '!!(window._cf_chl_opt)',
      );
      return jsBooleanValue(value);
    } catch (_) {
      // 页面还没建好 DOM，或脚本被 CSP 拦了：当作「不是挑战页」。
      return false;
    }
  }

  /// 实时回填 cookie（对齐 `WebViewActivity.onPageFinished`）。
  Future<void> _pushCookie(Uri uri, String cookie, String? userAgent) async {
    try {
      await LegadoClient.instance.call('Source.ImportCookie', [
        uri.toString(),
        cookie,
        userAgent ?? '',
      ]);
    } on Object catch (e) {
      // 回填失败不能打断阅读：验证结果仍会随「完成」一起交回内核。
      debugPrint('回填验证 cookie 失败: $e');
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    final uri = Uri.tryParse(_url) ?? widget.request.uri;
    final html = await WebViewBridge.html(_controller);
    final cookie = await WebViewBridge.cookies(_controller, uri);
    final userAgent = await WebViewBridge.userAgent(_controller);
    if (cookie != null && cookie.trim().isNotEmpty) {
      await _pushCookie(uri, cookie, userAgent);
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      BrowserVerificationResult(
        html: html,
        cookie: cookie,
        userAgent: userAgent,
        finalUrl: uri,
      ),
    );
  }

  void _cancel() {
    if (_finishing) return;
    _finishing = true;
    Navigator.of(context).pop(const BrowserVerificationResult(skipped: true));
  }

  Future<void> _copyLink() async {
    await Clipboard.setData(ClipboardData(text: _url));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('链接已复制')));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.request.title.isEmpty ? widget.request.host : widget.request.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          bottom: _progress < 100
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _progress <= 0 ? null : _progress / 100,
                    minHeight: 2,
                  ),
                )
              : null,
          actions: [
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller.reload(),
            ),
            IconButton(
              tooltip: '复制链接',
              icon: const Icon(Icons.link),
              onPressed: _copyLink,
            ),
            IconButton(
              tooltip: '完成',
              icon: const Icon(Icons.check),
              onPressed: _finish,
            ),
          ],
        ),
        body: Column(
          children: [
            if (_sawChallenge && !_solved)
              Container(
                width: double.infinity,
                color: scheme.secondaryContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Text(
                  '检测到人机验证，通过后会自动完成',
                  style: TextStyle(color: scheme.onSecondaryContainer),
                ),
              ),
            if (_error != null)
              Container(
                width: double.infinity,
                color: scheme.errorContainer,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '加载失败：$_error',
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                    TextButton(onPressed: _load, child: const Text('重试')),
                  ],
                ),
              ),
            Expanded(
              child: WebViewWidget(controller: _controller),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(onPressed: _cancel, child: const Text('取消')),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _finish, child: const Text('完成')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
