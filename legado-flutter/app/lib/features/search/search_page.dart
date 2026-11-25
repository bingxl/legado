import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/router/book_detail_route.dart';
import '../../core/widgets/book_cover.dart';
import '../settings/settings_models.dart';
import '../settings/settings_store.dart';
import 'search_results.dart';

/// 搜索页用到的控制面方法（Api 是共享冻结文件，缺的常量由 feature 自带）。
class _Api {
  static const listSources = 'Source.List';
  static const searchAll = 'Source.SearchAll';
  static const previewBook = 'Source.PreviewBook';
}

/// 搜索页（对应原版 `ui/book/search/SearchActivity`）。
///
/// 两种范围：默认「全部书源」走 `Source.SearchAll`（core 逐个源并发/串行搜），
/// 关掉开关则只搜选定书源。结果可按来源分组，也可平铺（每条带来源标签）。
///
/// [initialSourceId] 用于原版「发现」页长按书源 → 搜索的场景：
/// 直接锁定到那一个书源搜，不走全部书源。
class SearchPage extends StatefulWidget {
  SearchPage({
    super.key,
    this.initialSourceId,
    SettingsStore? settings,
  }) : _settings = settings ?? SettingsStore.instance;

  final int? initialSourceId;

  /// 搜索条件（精确搜索 / 范围）跟随内核设置落盘；测试可注入假 store。
  final SettingsStore _settings;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  List<Map<String, dynamic>> _sources = const [];
  List<Map<String, dynamic>> _items = const [];

  bool _grouped = true;

  /// 原版 SearchScope 字符串：空=全部书源，`名称::地址`=单源，`分组1,分组2`=多分组。
  String _scope = '';
  bool _precision = false;

  /// 「发现」页长按书源进来的目标 id，要等书源列表加载完才能换成 scope 字符串。
  int? _pendingSourceId;

  String _keyword = '';
  int _page = 0;
  bool _hasMore = true;
  bool _searched = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  /// 正在通过 PreviewBook 打开的书（bookUrl）。
  String? _openingUrl;

  /// 请求序号：切换范围/重新搜索会自增，晚到的旧响应丢弃。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 只用于刷新输入框尾部的「清空」按钮。
    _ctrl.addListener(_onTextChanged);
    final sourceId = widget.initialSourceId;
    if (sourceId != null && sourceId != 0) {
      // 从「发现」页长按书源 → 搜索进来的：锁定到该源。
      _pendingSourceId = sourceId;
      unawaited(_ensureSources());
    }
    unawaited(_loadConditions());
  }

  /// 读取上次使用的搜索条件。core 未连接时保持默认值，不打断页面渲染。
  Future<void> _loadConditions() async {
    try {
      await widget._settings.load();
      if (!mounted) return;
      final values = widget._settings.values;
      setState(() {
        _precision = settingsBool(values['search.precision'], false);
        // 从发现页锁定单源进来时，临时入口优先于上次记住的范围。
        final pending = _pendingSourceId;
        if (pending == null && _scope.isEmpty) {
          _scope = values['search.scope'] ?? '';
        }
      });
    } on Object {
      // 设置服务不可用（core 尚未初始化/单测未接内核）：用默认值即可。
    }
  }

  Future<void> _saveCondition(String key, String value) async {
    try {
      await widget._settings.setValue(key, value);
    } on Object {
      // 条件在内存里已生效；落盘失败不该让搜索页不可用。
    }
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scroll.dispose();
    _ctrl.removeListener(_onTextChanged);
    _ctrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.extentAfter < 320) _loadMore();
  }

  static int _idOf(Map<String, dynamic> source) =>
      (source['id'] as num?)?.toInt() ?? 0;

  Future<void> _ensureSources() async {
    if (_sources.isNotEmpty) return;
    try {
      final list = await LegadoClient.instance.callList(
        _Api.listSources,
        const [''],
      );
      if (!mounted) return;
      final loaded = [for (final s in list) if (s['enabled'] != false) s];
      final pending = _pendingSourceId;
      String? lockedScope;
      if (pending != null && pending > 0) {
        for (final s in loaded) {
          if (_idOf(s) == pending) {
            lockedScope = '${s['name'] ?? ''}::${s['url'] ?? ''}';
            break;
          }
        }
      }
      setState(() {
        _sources = loaded;
        if (lockedScope != null) {
          _scope = lockedScope;
          _pendingSourceId = null;
        }
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('加载书源失败：${e.message}');
    }
  }

  void _resetResults() {
    _seq++;
    _items = const [];
    _page = 0;
    _hasMore = true;
    _searched = false;
    _error = null;
    _loading = false;
    _loadingMore = false;
    _keyword = '';
  }

  Future<void> _search() async {
    final keyword = _ctrl.text.trim();
    if (keyword.isEmpty) {
      // 空关键词不发起请求：core 的 Search 会对空串直接报 INVALID_ARGUMENT。
      _toast('请输入书名或作者');
      return;
    }
    FocusScope.of(context).unfocus();
    await _runSearch(keyword);
  }

  Future<void> _retry() async {
    if (_keyword.isEmpty) return;
    await _runSearch(_keyword);
  }

  Future<void> _runSearch(String keyword) async {
    final mySeq = ++_seq;
    // 捕获条件快照：等待网络期间用户改了条件，旧响应仍按发起时的条件合并。
    final scope = _scope;
    final precision = _precision;
    setState(() {
      _keyword = keyword;
      _items = const [];
      _page = 0;
      _hasMore = true;
      _searched = true;
      _loading = true;
      _loadingMore = false;
      _error = null;
    });

    try {
      final data = await LegadoClient.instance.callList(_Api.searchAll, [
        keyword,
        1,
        scope,
      ]);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _items = mergeSearchResultsByRelevance(
          const [],
          data,
          keyword: keyword,
          precision: precision,
        );
        _page = 1;
        _hasMore = data.isNotEmpty;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loading ||
        _loadingMore ||
        !_hasMore ||
        !_searched ||
        _keyword.isEmpty ||
        _error != null) {
      return;
    }
    final mySeq = _seq;
    final keyword = _keyword;
    final scope = _scope;
    final precision = _precision;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await LegadoClient.instance.callList(_Api.searchAll, [
        keyword,
        next,
        scope,
      ]);
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _items = mergeSearchResultsByRelevance(
          _items,
          data,
          keyword: keyword,
          precision: precision,
        );
        _page = next;
        _hasMore = data.isNotEmpty;
        _loadingMore = false;
      });
    } on LegadoError catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _loadingMore = false;
        // 失败后停止自动翻页，避免滚动到底反复重试同一个坏页码。
        _hasMore = false;
      });
      _toast('加载下一页失败：${e.message}');
    }
  }

  /// 原版菜单里的「精确搜索」：切换后按当前关键词立即重搜。
  Future<void> _setPrecision(bool value) async {
    if (_precision == value) return;
    final keyword = _keyword;
    setState(() {
      _precision = value;
      _resetResults();
    });
    await _saveCondition('search.precision', value.toString());
    if (keyword.isNotEmpty && mounted) await _runSearch(keyword);
  }

  /// 范围选择器：空/单源/多分组，字符串直接沿用原版 SearchScope 格式。
  Future<void> _pickScope() async {
    await _ensureSources();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _ScopeSheet(
        sources: _sources,
        groups: _groups,
        current: _scope,
      ),
    );
    if (picked == null || picked == _scope || !mounted) return;
    final keyword = _keyword;
    setState(() {
      _scope = picked;
      _resetResults();
    });
    await _saveCondition('search.scope', picked);
    if (keyword.isNotEmpty && mounted) await _runSearch(keyword);
  }

  String get _scopeLabel {
    final raw = _scope.trim();
    if (raw.isEmpty) return '全部书源';
    final separator = raw.indexOf('::');
    if (separator >= 0) return raw.substring(0, separator).trim();
    return raw.split(',').where((part) => part.trim().isNotEmpty).join('、');
  }

  List<String> get _groups {
    final groups = <String>{};
    for (final source in _sources) {
      // Source.List 下发的是 SourceView，分组字段叫 group（不是书源的 bookSourceGroup）。
      final raw = '${source['group'] ?? source['bookSourceGroup'] ?? ''}';
      for (final part in raw.split(',')) {
        if (part.trim().isNotEmpty) groups.add(part.trim());
      }
    }
    return groups.toList()..sort();
  }

  /// 搜索结果只带书源地址（origin），PreviewBook 要书源 ID，这里做一次映射。
  Future<int> _resolveSourceId(Map<String, dynamic> item) async {
    await _ensureSources();
    // 锁定单源时优先用范围里的地址：结果里合并了多个来源，第一条未必是当前源。
    final separator = _scope.indexOf('::');
    if (separator >= 0) {
      final url = _scope.substring(separator + 2).trim();
      for (final source in _sources) {
        if ('${source['url'] ?? ''}' == url) return _idOf(source);
      }
    }
    final origin = '${item['origin'] ?? ''}'.trim();
    for (final source in _sources) {
      if ('${source['url'] ?? ''}' == origin) return _idOf(source);
    }
    return 0;
  }

  /// 打开书籍：PreviewBook 入库拿 bookId（试读态），再进详情页。
  Future<void> _openBook(Map<String, dynamic> item) async {
    if (_openingUrl != null) return;
    final bookUrl = '${item['bookUrl'] ?? ''}'.trim();
    if (bookUrl.isEmpty) {
      _toast('这条结果没有书籍链接，无法打开');
      return;
    }
    setState(() => _openingUrl = bookUrl);
    try {
      final sourceId = await _resolveSourceId(item);
      if (!mounted) return;
      if (sourceId == 0) {
        _toast('没有找到这条结果对应的书源，请先在书源管理里确认');
        return;
      }
      final brief = await LegadoClient.instance.call(_Api.previewBook, [
        sourceId,
        bookUrl,
        '${item['name'] ?? ''}',
        '${item['author'] ?? ''}',
        '${item['variable'] ?? ''}',
        // 详情规则常没有 coverUrl，搜索结果的封面在这里兜底（超星就是这种）。
        '${item['cover'] ?? ''}',
      ]);
      if (!mounted) return;
      final map = brief is Map<String, dynamic>
          ? brief
          : const <String, dynamic>{};
      final bookId = (map['id'] as num?)?.toInt() ?? 0;
      if (bookId == 0) {
        _toast('打开书籍失败：没有拿到书籍 ID');
        return;
      }
      // 走统一入口：push 前释放搜索框焦点，否则返回时焦点被恢复会弹输入法。
      openBookDetail(
        context,
        bookId: bookId,
        bookName: '${map['name'] ?? item['name'] ?? ''}',
      );
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('打开书籍失败：${e.message}');
    } finally {
      if (mounted) setState(() => _openingUrl = null);
    }
  }

  void _toast(String message) => showAppToast(context, message, mounted: mounted);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: '书名 / 作者',
            border: InputBorder.none,
            suffixIcon: _ctrl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _ctrl.clear(),
                  ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _search,
          ),
          IconButton(
            tooltip: _grouped ? '平铺显示' : '按书源分组',
            icon: Icon(
              _grouped ? Icons.view_list_outlined : Icons.workspaces_outline,
            ),
            onPressed: _items.isEmpty
                ? null
                : () => setState(() => _grouped = !_grouped),
          ),
          PopupMenuButton<String>(
            tooltip: '搜索选项',
            onSelected: (value) {
              if (value == 'precision') unawaited(_setPrecision(!_precision));
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                value: 'precision',
                child: Row(
                  children: [
                    Icon(
                      _precision
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Text('精确搜索'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          _scopeBar(),
          const Divider(height: 0.6),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _scopeBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: _pickScope,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.filter_alt_outlined, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '搜索范围：$_scopeLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (_precision)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('精确', style: TextStyle(fontSize: 11)),
                ),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return _emptyState(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        actionLabel: '重试',
        onAction: _retry,
      );
    }

    if (!_searched) {
      return _emptyState(
        icon: Icons.search,
        message: _scope.isEmpty
            ? '输入关键词，搜索全部书源'
            : '输入关键词，搜索「$_scopeLabel」',
        actionLabel: null,
      );
    }

    if (_items.isEmpty) {
      return _emptyState(
        icon: Icons.search_off,
        message: '没有找到「$_keyword」相关的书',
        actionLabel: null,
      );
    }

    final rows = _rows();
    return ListView.builder(
      controller: _scroll,
      itemCount: rows.length + 1,
      itemBuilder: (_, i) {
        if (i == rows.length) return _footer();
        final row = rows[i];
        if (row is _HeaderRow) {
          return _groupHeader(row.name, row.count);
        }
        final item = (row as _ItemRow).item;
        return _resultTile(item);
      },
    );
  }

  /// 把分组/平铺两种展示统一成「行」列表，便于共用一个滑动物理与分页监听。
  List<Object> _rows() {
    if (!_grouped) return [for (final item in _items) _ItemRow(item)];
    final rows = <Object>[];
    for (final group in groupBySource(_items)) {
      rows.add(_HeaderRow(group.name, group.items.length));
      rows.addAll(group.items.map(_ItemRow.new));
    }
    return rows;
  }

  Widget _groupHeader(String name, int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
          ),
          Text(
            '$count 本',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(Map<String, dynamic> item) {
    final scheme = Theme.of(context).colorScheme;
    final name = '${item['name'] ?? ''}';
    final author = '${item['author'] ?? ''}';
    final kind = '${item['kind'] ?? ''}';
    final originName = '${item['originName'] ?? ''}';
    final opening =
        _openingUrl != null && _openingUrl == '${item['bookUrl'] ?? ''}';

    final subtitle = [
      if (author.isNotEmpty) author,
      if (kind.isNotEmpty) kind,
      if (item['lastChapter'] != null && '${item['lastChapter']}'.isNotEmpty)
        '最新：${item['lastChapter']}',
    ].join(' · ');

    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 54,
        child: BookCover(
          name: name,
          url: '${item['cover'] ?? ''}',
          width: 40,
          height: 54,
          radius: 4,
          fontSize: 16,
        ),
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
      trailing: opening
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : (originName.isEmpty
                ? null
                : Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      originName,
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  )),
      onTap: opening ? null : () => _openBook(item),
    );
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (!_hasMore) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            '没有更多了',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }

  Widget _emptyState({
    required IconData icon,
    required String message,
    required String? actionLabel,
    VoidCallback? onAction,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: scheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (actionLabel != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}

/// 分组标题行。
class _HeaderRow {
  const _HeaderRow(this.name, this.count);

  final String name;
  final int count;
}

/// 结果行。
class _ItemRow {
  const _ItemRow(this.item);

  final Map<String, dynamic> item;
}

/// 搜索范围选择器，三种形态与原版 `SearchScope` 一致：
/// 空=全部书源，`名称::地址`=单源，逗号分隔=多分组。
class _ScopeSheet extends StatefulWidget {
  const _ScopeSheet({
    required this.sources,
    required this.groups,
    required this.current,
  });

  final List<Map<String, dynamic>> sources;
  final List<String> groups;
  final String current;

  @override
  State<_ScopeSheet> createState() => _ScopeSheetState();
}

class _ScopeSheetState extends State<_ScopeSheet> {
  late String _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.current;
  }

  String _sourceScope(Map<String, dynamic> source) =>
      '${source['name'] ?? ''}::${source['url'] ?? ''}';

  Set<String> get _selectedGroups {
    if (_draft.isEmpty || _draft.contains('::')) return const <String>{};
    return _draft
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toSet();
  }

  void _toggleGroup(String group, bool? selected) {
    final groups = _selectedGroups.toSet();
    if (selected == true) {
      groups.add(group);
    } else {
      groups.remove(group);
    }
    setState(() => _draft = groups.join(','));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Text('搜索范围', style: Theme.of(context).textTheme.titleMedium),
                  const Spacer(),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 0.6),
            Expanded(
              child: ListView(
                children: [
                  ListTile(
                    leading: Icon(
                      _draft.isEmpty
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                    ),
                    title: const Text('全部书源'),
                    onTap: () => setState(() => _draft = ''),
                  ),
                  for (final source in widget.sources)
                    ListTile(
                      leading: Icon(
                        _draft == _sourceScope(source)
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(
                        '${source['name'] ?? source['url'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${source['url'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                      onTap: () => setState(() => _draft = _sourceScope(source)),
                    ),
                  if (widget.groups.isNotEmpty) ...[
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Text(
                        '分组（可多选）',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                    for (final group in widget.groups)
                      CheckboxListTile(
                        value: _selectedGroups.contains(group),
                        title: Text(group),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (value) => _toggleGroup(group, value),
                      ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_draft),
                  child: const Text('确定'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
