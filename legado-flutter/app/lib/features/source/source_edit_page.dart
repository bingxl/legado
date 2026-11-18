import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'source_api.dart';
import 'source_utils.dart';

/// 书源编辑页（对应原版 `ui/book/source/edit/BookSourceEditActivity`）。
///
/// 两套入口共用一份数据：
///   * 表单字段（名称/分组/URL/备注/启用/排序）是管理字段，core 单独存；
///   * raw 是书源原始 JSON，规则引擎只认它。
/// 原生也是这个结构——所以改完表单不一定会改到 raw，界面上必须让用户看得见
/// 这份 raw（可折叠但默认展开），否则「为什么我改了名字规则里还是旧的」无解。
class SourceEditPage extends StatefulWidget {
  const SourceEditPage({super.key, this.sourceId});

  /// 为空或 0 时是新建。
  final int? sourceId;

  @override
  State<SourceEditPage> createState() => _SourceEditPageState();
}

class _SourceEditPageState extends State<SourceEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _group = TextEditingController();
  final _url = TextEditingController();
  final _comment = TextEditingController();
  final _order = TextEditingController(text: '0');
  final _raw = TextEditingController();

  bool _enabled = true;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  /// raw 的 JSON 格式错误提示；null 表示格式没问题。
  String? _rawError;

  int get _id => widget.sourceId ?? 0;
  bool get _isNew => _id == 0;

  @override
  void initState() {
    super.initState();
    _raw.addListener(_revalidateRaw);
    if (!_isNew) _load();
  }

  @override
  void dispose() {
    _raw.removeListener(_revalidateRaw);
    _name.dispose();
    _group.dispose();
    _url.dispose();
    _comment.dispose();
    _order.dispose();
    _raw.dispose();
    super.dispose();
  }

  void _revalidateRaw() {
    final err = SourceUtils.checkRawJson(_raw.text);
    if (err != _rawError) setState(() => _rawError = err);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final src = await SourceApi.get(_id);
      if (!mounted) return;
      setState(() {
        _name.text = '${src['name'] ?? ''}';
        _group.text = '${src['group'] ?? ''}';
        _url.text = '${src['url'] ?? ''}';
        _comment.text = '${src['comment'] ?? ''}';
        _order.text = '${(src['order'] as num?)?.toInt() ?? 0}';
        _raw.text = SourceUtils.prettyJson('${src['raw'] ?? ''}');
        _enabled = src['enabled'] != false;
        _rawError = SourceUtils.checkRawJson(_raw.text);
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

  // ── 页面 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? '新建书源' : '编辑书源'),
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
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _field(
                controller: _name,
                label: '名称',
                hint: '留空时用书源地址代替',
              ),
              _field(
                controller: _group,
                label: '分组',
                hint: '多个分组用逗号分隔',
              ),
              _field(
                controller: _url,
                label: '书源地址',
                hint: 'https://…',
                required: true,
                keyboardType: TextInputType.url,
                validator: (v) {
                  final text = (v ?? '').trim();
                  if (text.isEmpty) return '书源地址不能为空';
                  if (!text.startsWith('http')) return '需要以 http/https 开头';
                  return null;
                },
              ),
              _field(controller: _comment, label: '备注', maxLines: 2),
              const SizedBox(height: 4),
              _switchRow(),
              const SizedBox(height: 12),
              _rawSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    String? hint,
    bool required = false,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator,
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }

  Widget _switchRow() {
    return Row(
      children: [
        Expanded(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('启用'),
            subtitle: const Text('禁用后不参与搜索与发现'),
          ),
        ),
        SizedBox(
          width: 110,
          child: TextFormField(
            controller: _order,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '排序',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            validator: (v) {
              final text = (v ?? '').trim();
              if (text.isEmpty) return null;
              return int.tryParse(text) == null ? '请输入整数' : null;
            },
          ),
        ),
      ],
    );
  }

  Widget _rawSection() {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('原始 JSON', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton.icon(
              onPressed: _fillFromRaw,
              icon: const Icon(Icons.sync_alt, size: 18),
              label: const Text('用 JSON 补齐表单'),
            ),
            TextButton.icon(
              onPressed: _formatRaw,
              icon: const Icon(Icons.format_align_left, size: 18),
              label: const Text('格式化'),
            ),
          ],
        ),
        Text(
          '规则引擎只读这段内容；表单字段只影响管理列表。',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _raw,
          minLines: 12,
          maxLines: 40,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: '{\n  "bookSourceName": "…",\n  "bookSourceUrl": "…"\n}',
            errorText: _rawError,
            errorMaxLines: 3,
            filled: true,
            fillColor: scheme.surfaceContainerHighest,
          ),
        ),
      ],
    );
  }

  // ── 动作 ────────────────────────────────────────────────

  /// 把 raw 里的管理字段同步到表单（新建时最常用：只贴 JSON）。
  void _fillFromRaw() {
    final fields = SourceUtils.extractRawFields(_raw.text);
    if (fields.isEmpty) {
      _snack('JSON 里没有可识别的书源字段');
      return;
    }
    setState(() {
      if (fields['name'] != null) _name.text = fields['name']!;
      if (fields['group'] != null) _group.text = fields['group']!;
      if (fields['url'] != null) _url.text = fields['url']!;
      if (fields['comment'] != null) _comment.text = fields['comment']!;
    });
    _snack('已用 JSON 补齐表单');
  }

  void _formatRaw() {
    if (_raw.text.trim().isEmpty) return;
    final pretty = SourceUtils.prettyJson(_raw.text);
    if (pretty == _raw.text) {
      _snack(_rawError == null ? '已经是格式化状态' : 'JSON 有语法错误，无法格式化');
      return;
    }
    final selection = _raw.selection;
    setState(() {
      _raw.text = pretty;
      _rawError = SourceUtils.checkRawJson(pretty);
    });
    // 尽量把光标放回原位，避免格式化后视图跳到顶部。
    final max = pretty.length;
    _raw.selection = TextSelection.collapsed(
      offset: selection.baseOffset.clamp(0, max),
    );
  }

  Future<void> _save() async {
    if (_saving) return;

    // 只贴了 JSON 的情况：先补齐 URL/名称，否则 core 会直接拒绝。
    if (_url.text.trim().isEmpty && _raw.text.trim().isNotEmpty) {
      _fillFromRaw();
    }

    if (!(_formKey.currentState?.validate() ?? false)) return;

    if (_rawError != null) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('JSON 格式有误'),
          content: Text('$_rawError\n\n仍然保存吗？保存后需要手动修正才能使用该源。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('返回修改')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('仍然保存')),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() => _saving = true);
    try {
      final saved = await SourceApi.save(
        id: _id,
        name: _name.text.trim(),
        group: _group.text.trim(),
        url: _url.text.trim(),
        comment: _comment.text.trim(),
        raw: _raw.text.trim(),
        enabled: _enabled,
        order: int.tryParse(_order.text.trim()) ?? 0,
      );
      if (!mounted) return;
      // core 会把空名称补成 URL，用返回值回填，提示里才是最终名称。
      final finalName = '${saved['name'] ?? _name.text.trim()}';
      _snack(_isNew ? '已新建书源「$finalName」' : '已保存「$finalName」');
      Navigator.of(context).pop(true);
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('${e.code}: ${e.message}');
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}
