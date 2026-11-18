import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import 'source_api.dart';
import 'source_utils.dart';

/// 一条调试记录。
///
/// 注意：它不完全是「规则引擎的实时打点」。core 的 `SourceDebug.Start` 是
/// 宿主生命周期方法（`kernel.reflect.go` 的 lifecycleMethods 会把它过滤掉），
/// 没有暴露到控制面；控制面只剩 `SourceDebug.Running`，拿不到条目。
/// 因此本页用 `Source.Validate` 的一次性结果构造条目：
///   * 阶段 = issue.field 归类的 search/info/toc/content；
///   * 命中数 = 从消息里解析的「命中 N 条 / 共 N 章 / N 字」；
///   * 耗时 = 该次调用的整体耗时（阶段级精确耗时需要事件流，见 TODO）。
class _DebugEntry {
  _DebugEntry({
    required this.stage,
    required this.field,
    required this.level,
    required this.message,
    required this.time,
    this.elapsedMs,
    this.hits,
  });

  final String stage;
  final String field;
  final String level;
  final String message;
  final String time;
  final int? elapsedMs;
  final int? hits;

  bool get miss => SourceUtils.isMiss(level, message);
}

/// 调试动作：静态 / 联网 / 搜索实测。
enum _DebugRun { static, full, search }

/// 书源调试页（对应原版 `ui/book/source/debug/BookSourceDebugActivity`）。
///
/// 进入方式：书源列表的「调试」菜单会带上 initialSourceId。
class SourceDebugPage extends StatefulWidget {
  const SourceDebugPage({super.key, this.initialSourceId});

  final int? initialSourceId;

  @override
  State<SourceDebugPage> createState() => _SourceDebugPageState();
}

class _SourceDebugPageState extends State<SourceDebugPage> {
  final _keyword = TextEditingController(text: '我的');

  List<Map<String, dynamic>> _sources = const [];
  bool _loadingSources = true;
  String? _loadError;

  int _sourceId = 0;
  bool _running = false;
  String? _runError;

  List<_DebugEntry> _entries = const [];
  int _totalMs = 0;
  _DebugRun? _lastRun;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _loadSources() async {
    setState(() {
      _loadingSources = true;
      _loadError = null;
    });
    try {
      final list = await SourceApi.list();
      if (!mounted) return;
      setState(() {
        _sources = list;
        _loadingSources = false;
        final want = widget.initialSourceId;
        if (want != null && list.any((s) => _idOf(s) == want)) {
          _sourceId = want;
        } else if (_sourceId == 0 && list.isNotEmpty) {
          _sourceId = _idOf(list.first);
        }
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '${e.code}: ${e.message}';
        _loadingSources = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = '$e';
        _loadingSources = false;
      });
    }
  }

  static int _idOf(Map<String, dynamic> s) => (s['id'] as num?)?.toInt() ?? 0;

  Map<String, dynamic>? get _current {
    for (final s in _sources) {
      if (_idOf(s) == _sourceId) return s;
    }
    return null;
  }

  int get _missCount => _entries.where((e) => e.miss).length;

  // ── 页面 ────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源调试'),
        actions: [
          IconButton(
            tooltip: '重跑上一次调试',
            icon: const Icon(Icons.refresh),
            onPressed: _running || _lastRun == null ? null : _rerun,
          ),
          IconButton(
            tooltip: '清空结果',
            icon: const Icon(Icons.clear_all),
            onPressed: _entries.isEmpty ? null : _clear,
          ),
        ],
      ),
      body: Column(
        children: [
          _header(),
          const Divider(height: 0.6),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _header() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadingSources)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(minHeight: 2),
            )
          else if (_loadError != null)
            Row(
              children: [
                Expanded(child: Text(_loadError!, style: TextStyle(color: scheme.error))),
                TextButton(onPressed: _loadSources, child: const Text('重试')),
              ],
            )
          else
            DropdownButtonFormField<int>(
              // FormField 只在首帧读 initialValue；书源是异步加载的，
              // 用 key 跟随选中值重建，避免下拉框一直显示空。
              key: ValueKey<int>(_sourceId),
              initialValue: _sourceId == 0 ? null : _sourceId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '书源',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final s in _sources)
                  DropdownMenuItem(
                    value: _idOf(s),
                    child: Text(
                      '${s['name'] ?? ''}  ·  ${SourceUtils.domainOf('${s['url'] ?? ''}')}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _running
                  ? null
                  : (v) => setState(() => _sourceId = v ?? 0),
            ),
          const SizedBox(height: 10),
          TextField(
            controller: _keyword,
            enabled: !_running,
            decoration: const InputDecoration(
              labelText: '调试入口',
              hintText: '关键词 / 书籍地址 / 分类::地址',
              helperText: '完整校验与搜索实测使用这里的值',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _run(_lastRun ?? _DebugRun.full),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _running ? null : () => _run(_DebugRun.static),
                icon: const Icon(Icons.rule, size: 18),
                label: const Text('静态校验'),
              ),
              FilledButton.icon(
                onPressed: _running ? null : () => _run(_DebugRun.full),
                icon: _running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow, size: 18),
                label: const Text('完整校验'),
              ),
              OutlinedButton.icon(
                onPressed: _running ? null : () => _run(_DebugRun.search),
                icon: const Icon(Icons.search, size: 18),
                label: const Text('搜索实测'),
              ),
            ],
          ),
          if (_runError != null) ...[
            const SizedBox(height: 8),
            Text(_runError!, style: TextStyle(color: scheme.error, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _results() {
    if (_entries.isEmpty) return _empty();
    final grouped = <String, List<_DebugEntry>>{};
    for (final e in _entries) {
      grouped.putIfAbsent(e.stage, () => []).add(e);
    }
    final stages = grouped.keys.toList()
      ..sort((a, b) => SourceUtils.stageRank(a) - SourceUtils.stageRank(b));

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _summaryBar(),
        for (final stage in stages) ...[
          _stageHeader(stage, grouped[stage]!),
          for (final e in grouped[stage]!) _entryTile(e),
        ],
      ],
    );
  }

  Widget _summaryBar() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.surfaceContainerHighest,
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          _metric('条目', '${_entries.length}'),
          _metric('未命中', '$_missCount', alert: _missCount > 0),
          _metric('总耗时', '${_totalMs}ms'),
          if (_current != null)
            _metric('书源', '${_current!['name'] ?? ''}'),
        ],
      ),
    );
  }

  Widget _metric(String label, String value, {bool alert = false}) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: TextStyle(fontSize: 12, color: scheme.outline)),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: alert ? scheme.error : scheme.onSurface,
          ),
        ),
      ],
    );
  }

  Widget _stageHeader(String stage, List<_DebugEntry> items) {
    final scheme = Theme.of(context).colorScheme;
    final miss = items.where((e) => e.miss).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Row(
        children: [
          Icon(Icons.timeline, size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Text(stage, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Text(
            '(${items.length})',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const Spacer(),
          if (miss > 0)
            Text(
              '未命中 $miss',
              style: TextStyle(fontSize: 12, color: scheme.error),
            ),
        ],
      ),
    );
  }

  Widget _entryTile(_DebugEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final color = e.miss
        ? scheme.error
        : e.level == 'warning'
            ? Colors.orange
            : Colors.green;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      decoration: BoxDecoration(
        color: e.miss ? scheme.errorContainer.withValues(alpha: 0.35) : null,
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(4),
          bottomRight: Radius.circular(4),
        ),
      ),
      child: ListTile(
        dense: true,
        visualDensity: VisualDensity.compact,
        leading: Icon(
          e.miss
              ? Icons.cancel_outlined
              : e.level == 'warning'
                  ? Icons.warning_amber_outlined
                  : Icons.check_circle_outline,
          size: 18,
          color: color,
        ),
        title: Text(e.message, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          [
            e.field.isEmpty ? '—' : e.field,
            if (e.time.isNotEmpty) e.time,
            if (e.elapsedMs != null) '本次 ${e.elapsedMs}ms',
          ].join(' · '),
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
        trailing: e.hits == null
            ? null
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '命中 ${e.hits}',
                  style: TextStyle(fontSize: 11, color: scheme.onSecondaryContainer),
                ),
              ),
      ),
    );
  }

  Widget _empty() {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.bug_report_outlined, size: 40, color: scheme.outline),
        const SizedBox(height: 12),
        const Center(child: Text('选一个书源，然后开始调试')),
        const SizedBox(height: 16),
        Text(
          '三种模式的区别：\n'
          '· 静态校验：不联网，只检查必填字段与规则语法；\n'
          '· 完整校验：真发请求，按「搜索 → 详情 → 目录 → 正文」依次实测；\n'
          '· 搜索实测：只用关键词跑一次搜索，看命中条数与结果。\n\n'
          '失败条目会标红；阶段按 core 返回的字段归类。',
          style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.6),
        ),
      ],
    );
  }

  // ── 执行 ────────────────────────────────────────────────

  void _clear() {
    setState(() {
      _entries = const [];
      _totalMs = 0;
      _runError = null;
      _lastRun = null;
    });
  }

  void _rerun() {
    final run = _lastRun;
    if (run != null) _run(run);
  }

  Future<void> _run(_DebugRun mode) async {
    if (_running) return;
    if (_sourceId == 0) {
      setState(() => _runError = '请先选择书源');
      return;
    }
    final keyword = _keyword.text.trim();
    if (mode != _DebugRun.static && keyword.isEmpty) {
      setState(() => _runError = '请填写调试入口（关键词或书籍地址）');
      return;
    }

    setState(() {
      _running = true;
      _runError = null;
      _lastRun = mode;
      _entries = const [];
      _totalMs = 0;
    });

    final time = _clockNow();
    final sw = Stopwatch()..start();
    try {
      final List<_DebugEntry> entries;
      switch (mode) {
        case _DebugRun.static:
          final issues = await SourceApi.validate([_sourceId]);
          sw.stop();
          entries = _entriesFromIssues(issues, time, sw.elapsedMilliseconds);
        case _DebugRun.full:
          final issues = await SourceApi.validate(
            [_sourceId],
            search: true,
            info: true,
            toc: true,
            content: true,
            keyword: keyword,
          );
          sw.stop();
          entries = _entriesFromIssues(issues, time, sw.elapsedMilliseconds);
        case _DebugRun.search:
          final results = await SourceApi.search(_sourceId, keyword);
          sw.stop();
          entries = _entriesFromSearch(results, time, sw.elapsedMilliseconds);
      }
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _totalMs = sw.elapsedMilliseconds;
        _running = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _runError = '${e.code}: ${e.message}';
        _running = false;
      });
    }
  }

  /// 把 core 的校验结果摊平成条目。
  ///
  /// 一次调用返回的是「所有阶段的问题」，没有单阶段耗时；
  /// 因此 elapsedMs 记的是整次调用的耗时，界面文案是「本次」而不是「阶段」。
  List<_DebugEntry> _entriesFromIssues(
    List<Map<String, dynamic>> results,
    String time,
    int elapsedMs,
  ) {
    final out = <_DebugEntry>[];
    for (final r in results) {
      final issues = (r['issues'] as List?) ?? const [];
      for (final raw in issues) {
        if (raw is! Map) continue;
        final issue = raw.cast<String, dynamic>();
        final field = '${issue['field'] ?? ''}';
        final message = '${issue['message'] ?? ''}';
        out.add(
          _DebugEntry(
            stage: SourceUtils.stageOfField(field),
            field: field,
            level: '${issue['level'] ?? ''}',
            message: message,
            time: time,
            elapsedMs: elapsedMs,
            hits: SourceUtils.hitCountOf(message),
          ),
        );
      }
      if (issues.isEmpty) {
        out.add(
          _DebugEntry(
            stage: '其他',
            field: '',
            level: 'info',
            message: '没有发现问题，规则可用',
            time: time,
            elapsedMs: elapsedMs,
          ),
        );
      }
    }
    if (out.isEmpty) {
      out.add(
        _DebugEntry(
          stage: '其他',
          field: '',
          level: 'info',
          message: '校验没有返回任何条目',
          time: time,
          elapsedMs: elapsedMs,
        ),
      );
    }
    return out;
  }

  /// 搜索实测：命中数 + 前几条结果。
  List<_DebugEntry> _entriesFromSearch(
    List<Map<String, dynamic>> results,
    String time,
    int elapsedMs,
  ) {
    final out = <_DebugEntry>[];
    out.add(
      _DebugEntry(
        stage: '搜索',
        field: 'search',
        level: results.isEmpty ? 'error' : 'info',
        message: results.isEmpty
            ? '搜索无结果（关键词无匹配，或站点反爬/要求登录）'
            : '搜索成功，命中 ${results.length} 条',
        time: time,
        elapsedMs: elapsedMs,
        hits: results.length,
      ),
    );
    final preview = results.take(5).toList();
    for (final r in preview) {
      final name = '${r['name'] ?? ''}';
      final author = '${r['author'] ?? ''}';
      final bookUrl = '${r['bookUrl'] ?? ''}';
      out.add(
        _DebugEntry(
          stage: '搜索',
          field: 'bookUrl',
          level: 'info',
          message: author.isEmpty ? name : '$name · $author',
          time: time,
          elapsedMs: elapsedMs,
          hits: null,
        ),
      );
      if (bookUrl.isNotEmpty) {
        out.add(
          _DebugEntry(
            stage: '搜索',
            field: 'bookUrl',
            level: 'info',
            message: bookUrl,
            time: time,
            elapsedMs: null,
          ),
        );
      }
    }
    return out;
  }

  String _clockNow() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }
}
