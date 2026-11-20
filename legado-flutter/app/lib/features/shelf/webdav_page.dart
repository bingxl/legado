import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'shelf_api.dart';

/// WebDAV 书库页：配置连接、浏览/扫描远程书籍并导入书架，以及数据库备份。
///
/// 对应原版 `RemoteBookActivity`（远程书籍）+ WebDAV 备份设置。
class WebDavPage extends StatefulWidget {
  const WebDavPage({super.key});

  @override
  State<WebDavPage> createState() => _WebDavPageState();
}

class _WebDavPageState extends State<WebDavPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  Map<String, dynamic> _config = const {};
  bool _loadingConfig = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadConfig();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await ShelfApi.webdavConfig();
      if (!mounted) return;
      setState(() {
        _config = cfg;
        _loadingConfig = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingConfig = false;
        _config = {'url': '', 'username': '', 'rootPath': 'legado'};
      });
      _snack('读取配置失败: ${e.message}');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WebDAV 书库'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.import_contacts), text: '远程书籍'),
            Tab(icon: Icon(Icons.backup), text: '备份同步'),
          ],
        ),
      ),
      body: _loadingConfig
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabs,
              children: [
                _RemoteBooksTab(config: _config, onConfigChanged: _loadConfig, snack: _snack),
                _BackupTab(snack: _snack),
              ],
            ),
    );
  }
}

/// 远程书籍：配置 → 扫描 → 勾选 → 导入。
class _RemoteBooksTab extends StatefulWidget {
  const _RemoteBooksTab({
    required this.config,
    required this.onConfigChanged,
    required this.snack,
  });

  final Map<String, dynamic> config;
  final Future<void> Function() onConfigChanged;
  final void Function(String) snack;

  @override
  State<_RemoteBooksTab> createState() => _RemoteBooksTabState();
}

class _RemoteBooksTabState extends State<_RemoteBooksTab> {
  List<Map<String, dynamic>> _books = const [];
  final Set<String> _selected = <String>{};
  bool _busy = false;
  String _status = '';

  bool get _configured => (widget.config['configured'] as bool?) ?? false;

  Future<void> _openConfig() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => WebDavConfigPage(config: widget.config)),
    );
    if (changed == true) await widget.onConfigChanged();
  }

  Future<void> _scan() async {
    if (!_configured) {
      widget.snack('请先配置 WebDAV');
      await _openConfig();
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在扫描远程书库…';
    });
    try {
      final books = await ShelfApi.webdavScan('');
      if (!mounted) return;
      setState(() {
        _books = books;
        _selected.clear();
        _status = books.isEmpty ? '没有找到书籍文件' : '找到 ${books.length} 本，请选择后导入';
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() => _status = '扫描失败: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importSelected() async {
    if (_selected.isEmpty) {
      widget.snack('请先勾选书籍');
      return;
    }
    setState(() {
      _busy = true;
      _status = '正在下载并导入 ${_selected.length} 本…';
    });
    try {
      await ShelfApi.startImport(_selected.toList(), 0);
      // 轮询导入进度。
      Map<String, dynamic> job;
      while (true) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
        job = await ShelfApi.importStatus();
        final state = '${job['state']}';
        if (!mounted) return;
        setState(() {
          _status = '导入中… ${job['done'] ?? 0}/${job['total'] ?? 0}'
              '${(job['message'] as String?)?.isNotEmpty == true ? ' · ${job['message']}' : ''}';
        });
        if (state != 'running') break;
      }
      final imported = (job['imported'] as List?)?.length ?? 0;
      final failed = (job['failed'] as num?)?.toInt() ?? 0;
      widget.snack('导入完成：成功 $imported 本，失败 $failed 本');
      if (mounted) {
        setState(() => _status = '导入完成：成功 $imported 本，失败 $failed 本');
      }
    } on LegadoError catch (e) {
      widget.snack('导入失败: ${e.message}');
      if (mounted) setState(() => _status = '导入失败: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await ShelfApi.cancelImport();
      widget.snack('已取消导入');
    } on LegadoError catch (e) {
      widget.snack('取消失败: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Card(
          margin: const EdgeInsets.all(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(
                  _configured ? Icons.cloud_done : Icons.cloud_off,
                  color: _configured ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _configured
                        ? '${widget.config['url'] ?? ''}\n目录: ${widget.config['rootPath'] ?? ''}'
                        : '尚未配置 WebDAV',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton(
                  onPressed: _openConfig,
                  child: const Text('配置'),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.search),
                label: const Text('扫描书库'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _busy || _selected.isEmpty ? null : _importSelected,
                icon: const Icon(Icons.download),
                label: Text('导入 (${_selected.length})'),
              ),
              const SizedBox(width: 8),
              if (_busy)
                TextButton(onPressed: _cancel, child: const Text('取消')),
            ],
          ),
        ),
        if (_status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(_status, style: const TextStyle(color: Colors.grey)),
          ),
        Expanded(
          child: ListView.separated(
            itemCount: _books.length,
            separatorBuilder: (_, _) => const Divider(height: 0.5),
            itemBuilder: (_, i) {
              final b = _books[i];
              final path = '${b['path'] ?? ''}';
              return CheckboxListTile(
                value: _selected.contains(path),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(path);
                  } else {
                    _selected.remove(path);
                  }
                }),
                title: Text(
                  '${b['name'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('${b['format'] ?? ''} · ${b['size'] ?? 0} 字节'),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// WebDAV 配置表单（可测连接）。
class WebDavConfigPage extends StatefulWidget {
  const WebDavConfigPage({super.key, required this.config});

  final Map<String, dynamic> config;

  @override
  State<WebDavConfigPage> createState() => _WebDavConfigPageState();
}

class _WebDavConfigPageState extends State<WebDavConfigPage> {
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _rootPath;
  late bool _autoSync;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: '${widget.config['url'] ?? ''}');
    _username = TextEditingController(text: '${widget.config['username'] ?? ''}');
    _password = TextEditingController();
    _rootPath = TextEditingController(text: '${widget.config['rootPath'] ?? 'legado'}');
    _autoSync = (widget.config['autoSync'] as bool?) ?? true;
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _rootPath.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await _save();
      await ShelfApi.webdavTest();
      _snack('连接成功');
    } on LegadoError catch (e) {
      _snack('连接失败: ${e.message}');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    await ShelfApi.saveWebdavConfig(
      url: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text,
      rootPath: _rootPath.text.trim(),
      autoSync: _autoSync,
    );
  }

  Future<void> _saveAndBack() async {
    try {
      await _save();
      if (!mounted) return;
      Navigator.pop(context, true);
    } on LegadoError catch (e) {
      _snack('保存失败: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebDAV 配置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.jianguoyun.com/dav/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(
              labelText: widget.config['hasPassword'] == true
                  ? '密码（留空保持不变）'
                  : '密码',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _rootPath,
            decoration: const InputDecoration(
              labelText: '根目录（相对服务器）',
              hintText: 'legado',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            value: _autoSync,
            onChanged: (v) => setState(() => _autoSync = v),
            title: const Text('自动同步阅读进度'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.wifi_find),
                  label: Text(_testing ? '测试中…' : '测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _saveAndBack,
                  icon: const Icon(Icons.save),
                  label: const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 备份同步：上传到 WebDAV / 查看状态。
class _BackupTab extends StatefulWidget {
  const _BackupTab({required this.snack});

  final void Function(String) snack;

  @override
  State<_BackupTab> createState() => _BackupTabState();
}

class _BackupTabState extends State<_BackupTab> {
  bool _busy = false;
  String _message = '';

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _message = '正在备份并上传…';
    });
    try {
      // 触发一次备份，之后只轮询状态（uploadBackup 本身会等到完成才返回）。
      final progress = await ShelfApi.uploadBackup();
      if (!mounted) return;
      final state = '${progress['state']}';
      setState(() {
        _message = '${progress['phase']} · ${progress['message']}';
      });
      widget.snack('${progress['message']}  ($state)');
    } on LegadoError catch (e) {
      widget.snack('备份失败: ${e.message}');
      if (mounted) setState(() => _message = '备份失败: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.backup, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              '把当前数据库备份到 WebDAV',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            if (_message.isNotEmpty)
              Text(_message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _busy ? null : _upload,
              icon: const Icon(Icons.cloud_upload),
              label: Text(_busy ? '上传中…' : '上传备份'),
            ),
          ],
        ),
      ),
    );
  }
}
