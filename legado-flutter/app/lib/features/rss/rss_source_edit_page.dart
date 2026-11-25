import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import 'rss_api.dart';
import 'rss_text.dart';

/// 订阅源编辑页（对应原版 `ui/rss/source/edit/RssSourceEditActivity`）。
///
/// core 没有 `Rss.Source.Get`，编辑时只能从列表里挑出目标源；
/// 订阅源字段本来就少（名称/地址/分组/启用），为此多开一个方法不值当。
class RssSourceEditPage extends StatefulWidget {
  const RssSourceEditPage({super.key, this.sourceId});

  /// 为空或 0 时是新建。
  final int? sourceId;

  @override
  State<RssSourceEditPage> createState() => _RssSourceEditPageState();
}

class _RssSourceEditPageState extends State<RssSourceEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _group = TextEditingController();

  bool _enabled = true;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  int get _id => widget.sourceId ?? 0;
  bool get _isNew => _id == 0;

  @override
  void initState() {
    super.initState();
    if (!_isNew) _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _group.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await RssApi.listSources();
      final source = sources.cast<Map<String, dynamic>?>().firstWhere(
            (s) => rssInt(s?['id']) == _id,
            orElse: () => null,
          );
      if (!mounted) return;
      if (source == null) {
        setState(() {
          _error = '订阅源不存在，可能已被删除';
          _loading = false;
        });
        return;
      }
      setState(() {
        _name.text = '${source['name'] ?? ''}';
        _url.text = '${source['url'] ?? ''}';
        _group.text = '${source['group'] ?? ''}';
        _enabled = source['enabled'] != false;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _saving = true);
    try {
      final saved = await RssApi.saveSource(
        id: _id,
        name: _name.text.trim(),
        url: _url.text.trim(),
        group: _group.text.trim(),
        enabled: _enabled,
      );
      if (!mounted) return;
      // 名称留空时 core 会用地址补，提示里回填最终名称才不误导。
      final finalName = '${saved['name'] ?? _url.text.trim()}';
      _toast(_isNew ? '已新增订阅源「$finalName」' : '已保存「$finalName」');
      Navigator.of(context).pop(true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('${e.code}: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败：$e');
    }
  }

  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新增订阅源' : '编辑订阅源'),
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined, size: 20),
            label: const Text('保存'),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_outlined, size: 36),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }

    return Form(
      key: _formKey,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '留空时用订阅地址代替',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                validator: RssText.validateFeedUrl,
                decoration: const InputDecoration(
                  labelText: '订阅地址 *',
                  hintText: 'https://example.com/feed.xml',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _group,
                decoration: const InputDecoration(
                  labelText: '分组',
                  hintText: '可选，例如「科技」',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: _enabled,
                onChanged: (value) => setState(() => _enabled = value),
                title: const Text('启用'),
                subtitle: const Text('停用后不参与刷新'),
              ),
              const SizedBox(height: 4),
              Text(
                '保存后可在列表下拉刷新，core 会把新源的第一批文章抓下来。',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
