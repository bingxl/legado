import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bridge/legado_client.dart';
import 'source_api.dart';

/// 书源登录面板。
///
/// 三种登录方式在界面上表现不同，但共用同一套字段：
///
/// - `js` / `request`：填表单 → 点「登录」，core 执行脚本或按 URL 规则发请求；
/// - `page`：core 只能给出登录页地址，用户去浏览器登录后把请求头粘回来；
/// - `header`：没有 loginUrl，只能粘贴请求头。
///
/// 「粘贴请求头」始终可用：它是 page 方式在没有内嵌浏览器时唯一的落地路径。
class SourceLoginPage extends StatefulWidget {
  const SourceLoginPage({super.key, required this.sourceId});

  final int sourceId;

  @override
  State<SourceLoginPage> createState() => _SourceLoginPageState();
}

class _SourceLoginPageState extends State<SourceLoginPage> {
  final Map<String, String> _form = <String, String>{};
  final TextEditingController _headerCtrl = TextEditingController();

  Map<String, dynamic>? _profile;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _message;
  Map<String, dynamic>? _probe;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _headerCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profile = await SourceApi.loginProfile(widget.sourceId);
      if (!mounted) return;
      _headerCtrl.text = '${profile['header'] ?? ''}';
      setState(() {
        _profile = profile;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(
    Future<Map<String, dynamic>> Function() action, {
    bool reload = true,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await action();
      if (!mounted) return;
      final message = '${result['message'] ?? ''}';
      final openUrl = '${result['openUrl'] ?? ''}';
      setState(() {
        _message = message.isEmpty ? null : message;
        _probe = null;
      });
      if (openUrl.isNotEmpty) {
        await _showOpenUrl(openUrl);
      } else {
        _snack(message.isEmpty ? '完成' : message);
      }
      if (reload) await _load();
    } on LegadoError catch (e) {
      _snack('失败：${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _login() => _run(() => SourceApi.login(widget.sourceId, _form));

  Future<void> _saveHeader() => _run(
        () => SourceApi.saveLoginHeader(widget.sourceId, _headerCtrl.text),
      );

  Future<void> _check() => _run(
        () async {
          final result = await SourceApi.checkLogin(widget.sourceId, '');
          if (mounted) setState(() => _probe = result);
          return <String, dynamic>{
            'message': '${result['detail'] ?? ''}',
          };
        },
        reload: false,
      );

  Future<void> _clear(bool withForm) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除登录态'),
        content: Text(
          withForm
              ? '将清除 cookie 与粘贴的请求头，下次抓取会重新要求登录。'
              : '只清除 cookie 与登录回执，保留粘贴的请求头。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await SourceApi.clearLogin(widget.sourceId, withForm);
      return <String, dynamic>{'message': '已清除登录态'};
    });
  }

  Future<void> _showOpenUrl(String url) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要网页登录'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('这个书源只能人工登录。请复制下面的地址，在浏览器里登录，'
                '然后把「网络」面板里的请求头（含 Cookie 那一行）粘贴到本页下方。'),
            const SizedBox(height: 12),
            SelectableText(url, style: const TextStyle(fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (ctx.mounted) Navigator.pop(ctx);
              _snack('地址已复制');
            },
            child: const Text('复制地址'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_profile?['sourceName'] ?? '书源登录'}'),
        actions: [
          IconButton(
            tooltip: '检测登录状态',
            icon: const Icon(Icons.health_and_safety_outlined),
            onPressed: _busy || _loading ? null : _check,
          ),
          PopupMenuButton<int>(
            tooltip: '清除',
            onSelected: (v) => _clear(v == 1),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('清除 cookie（保留请求头）')),
              PopupMenuItem(value: 1, child: Text('清除全部（含请求头）')),
            ],
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final profile = _profile ?? const <String, dynamic>{};
    final kind = '${profile['kind'] ?? 'header'}';
    final fields = (profile['fields'] as List?) ?? const [];
    final inputFields = fields
        .whereType<Map>()
        .where((f) => '${f['type']}' != 'button')
        .toList();
    final buttons = fields
        .whereType<Map>()
        .where((f) => '${f['type']}' == 'button')
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _statusCard(profile, kind),
        if (inputFields.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text('登录表单', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final field in inputFields)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                decoration: InputDecoration(
                  labelText: '${field['name'] ?? ''}',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                obscureText: '${field['type']}' == 'password',
                onChanged: (v) => _form['${field['name'] ?? ''}'] = v,
              ),
            ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _login,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(kind == 'page' ? Icons.open_in_browser : Icons.login),
          label: Text(kind == 'page' ? '获取登录地址' : '登录'),
        ),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final button in buttons)
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(
                            () => SourceApi.runLoginAction(
                              widget.sourceId,
                              '${button['action'] ?? ''}',
                              _form,
                            ),
                          ),
                  child: Text('${button['name'] ?? '执行'}'),
                ),
            ],
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          _hintCard(_message!),
        ],
        if (_probe != null) ...[
          const SizedBox(height: 12),
          _probeCard(_probe!),
        ],
        const Divider(height: 32),
        const Text('粘贴请求头', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(
          '从浏览器开发者工具的「网络」面板复制某次请求的请求头，整段粘贴即可。'
          '只要包含 Cookie 那一行；UA / Referer 也会一并用于抓取。',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _headerCtrl,
          minLines: 4,
          maxLines: 10,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Cookie: a=1; b=2\nUser-Agent: ...',
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: _busy ? null : _saveHeader,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存请求头'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () {
                      _headerCtrl.clear();
                      _saveHeader();
                    },
              child: const Text('清空'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _statusCard(Map<String, dynamic> profile, String kind) {
    final scheme = Theme.of(context).colorScheme;
    final hasCookie = profile['hasCookie'] == true;
    final kindLabel = switch (kind) {
      'js' => '脚本登录（loginUrl 带 JS）',
      'request' => '接口登录（loginUrl 是 URL 规则）',
      'page' => '网页登录（需人工在浏览器完成）',
      _ => '仅支持粘贴请求头',
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasCookie ? Icons.lock_outline : Icons.lock_open_outlined,
                  size: 18,
                  color: hasCookie ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 8),
                Text(
                  hasCookie ? '已登录' : '未登录',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: hasCookie ? scheme.primary : scheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _kv('登录方式', kindLabel),
            _kv('书源地址', '${profile['sourceUrl'] ?? ''}'),
            if ('${profile['cookieMask'] ?? ''}'.isNotEmpty)
              _kv('Cookie', '${profile['cookieMask']}'),
            if ('${profile['info'] ?? ''}'.isNotEmpty)
              _kv('最近回执', '${profile['info']}'),
            if ('${profile['checkJs'] ?? ''}'.isNotEmpty)
              _kv('检测脚本', '已配置 loginCheckJs'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String key, String value) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 72,
              child: Text(
                key,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
            Expanded(
              child: Text(value, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );

  Widget _hintCard(String message) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: const TextStyle(fontSize: 12)),
    );
  }

  Widget _probeCard(Map<String, dynamic> probe) {
    final needLogin = probe['needLogin'] == true;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: needLogin
            ? scheme.errorContainer.withValues(alpha: 0.5)
            : scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            needLogin ? '需要登录' : '登录有效',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'HTTP ${probe['statusCode'] ?? 0} · ${probe['detail'] ?? ''}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}
