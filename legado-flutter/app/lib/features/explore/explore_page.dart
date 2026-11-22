import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';
import 'explore_api.dart';

/// 发现页（对应原版 `ui/main/explore/ExploreFragment`）。
///
/// 结构照搬原版：标题栏右侧是「筛选发现源」搜索框 + 「分组」菜单，
/// 主体是一列书源；点书源展开它的发现分类（胶囊 chip 排布），
/// 点分类进入二级页看书单。**不是**把书单铺在一页里——原版就是两级。
///
/// 交互对齐点：
///   - 一次只展开一个书源（原版 `exIndex` 是单个下标）；
///   - 展开时才异步解析分类，解析期间标题行右侧转圈；
///   - 长按书源标题弹出菜单：编辑 / 置顶 / 登录 / 搜索 / 刷新 / 删除；
///   - 搜索框输入 `group:xxx` 表示按分组过滤（与原版同义），
///     「分组」菜单点某一项等价于把搜索框填成 `group:xxx`。
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  /// 书源列表（已过滤「启用 + 开启发现 + 有 exploreUrl」）。
  List<Map<String, dynamic>> _sources = const [];

  /// 已展开的书源 ID，对齐原版的 `exIndex`（同时只有一个展开）。
  ///
  /// 用 ID 而不是下标：搜索过滤会改变列表顺序，下标会指到别的书源。
  int? _expandedId;

  /// 各书源解析出的分类缓存：sourceId → 分类列表。
  final Map<int, List<Map<String, dynamic>>> _kinds = {};

  /// 正在解析分类的书源。
  final Set<int> _loadingKinds = {};

  bool _loading = true;
  String? _error;

  /// 搜索框文本。`group:` 前缀走分组过滤，其余按书源名过滤。
  String _query = '';

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onQueryChanged);
    _loadSources();
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onQueryChanged);
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    // setState 会被 TextField 自己的 rebuild 覆盖，这里只需要驱动列表刷新。
    setState(() => _query = _ctrl.text.trim());
  }

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ExploreApi.listSources();
      if (!mounted) return;
      setState(() {
        _sources = list;
        _loading = false;
        // 书源列表变了，原来的展开项可能已经不在列表里。
        if (_expandedId != null &&
            !list.any((s) => _idOf(s) == _expandedId)) {
          _expandedId = null;
        }
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  /// 当前生效的过滤结果。
  ///
  /// `group:xxx` 走分组过滤（与原版 `flowGroupExplore` 同义），
  /// 其余按书源名包含匹配（原版 `flowExplore(key)`）。
  List<Map<String, dynamic>> _visibleSources() {
    final query = _query;
    if (query.isEmpty) return _sources;
    if (query.startsWith('group:')) {
      final group = query.substring('group:'.length).trim();
      return _sources
          .where((s) => '${s['group'] ?? ''}'.trim() == group)
          .toList();
    }
    final lower = query.toLowerCase();
    return _sources
        .where((s) => '${s['name'] ?? ''}'.toLowerCase().contains(lower))
        .toList();
  }

  /// 书源所属的全部分组（原版菜单里列的就是这些）。
  List<String> _groups() {
    final seen = <String>{};
    for (final source in _sources) {
      final group = '${source['group'] ?? ''}'.trim();
      if (group.isNotEmpty) seen.add(group);
    }
    final list = seen.toList()..sort();
    return list;
  }

  Future<void> _toggleExpand(Map<String, dynamic> source) async {
    final id = _idOf(source);
    if (_expandedId == id) {
      setState(() => _expandedId = null);
      return;
    }
    setState(() => _expandedId = id);
    if (_kinds.containsKey(id)) return;
    await _loadKinds(id);
  }

  Future<void> _loadKinds(int sourceId) async {
    setState(() => _loadingKinds.add(sourceId));
    try {
      final kinds = await ExploreApi.kinds(sourceId);
      if (!mounted) return;
      setState(() {
        _kinds[sourceId] = kinds;
        _loadingKinds.remove(sourceId);
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingKinds.remove(sourceId);
        // 解析失败时保留空列表：原版是直接不显示分类区，不弹错误。
        _kinds[sourceId] = const [];
      });
      _toast('解析分类失败：${e.message}');
    }
  }

  /// 点分类：进二级页看书单（原版 ExploreShowActivity）。
  void _openKind(Map<String, dynamic> source, Map<String, dynamic> kind) {
    final title = '${kind['title'] ?? ''}';
    final url = '${kind['url'] ?? ''}'.trim();
    if (url.isEmpty) return;
    if (title.startsWith('ERROR:')) {
      // 原版对解析失败的分类弹出错误文本，这里照做。
      _showErrorDialog('ERROR', url);
      return;
    }
    // 顶部筛选框可能还持有焦点：直接 push 的话返回时焦点被恢复，
    // 安卓端会重新弹输入法（与书籍详情页同一类问题）。
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.pushNamed(
      context,
      RouteNames.exploreDetail,
      arguments: {
        'sourceId': _idOf(source),
        'kindTitle': title,
        'kindUrl': url,
      },
    );
  }

  void _showErrorDialog(String title, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  // ── 长按菜单（原版 explore_item.xml） ─────────────────────

  /// 长按书源标题弹出的菜单（原版 explore_item.xml + PopupMenu）。
  ///
  /// 菜单锚定在长按位置，和原版一致。
  Future<void> _showSourceMenu(
    Map<String, dynamic> source,
    Offset anchor,
  ) async {
    final id = _idOf(source);
    final url = '${source['url'] ?? ''}';
    final hasLogin = source['hasLoginUrl'] == true;
    // 纯发现源没有搜索地址，点了「搜索」内核会直接报错，所以不显示这一项。
    final hasSearch = source['hasSearchUrl'] != false;

    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        anchor.dx,
        anchor.dy,
        anchor.dx + 220,
        anchor.dy,
      ),
      items: [
        _menuItem('编辑', Icons.edit_outlined),
        _menuItem('置顶', Icons.vertical_align_top),
        if (hasLogin) _menuItem('登录', Icons.login),
        if (hasSearch) _menuItem('搜索', Icons.search),
        _menuItem('刷新', Icons.refresh),
        _menuItem('删除', Icons.delete_outline),
      ],
    );
    if (!mounted || action == null) return;

    switch (action) {
      case '编辑':
        Navigator.pushNamed(
          context,
          RouteNames.sourceEdit,
          arguments: {'sourceId': id},
        );
        break;
      case '置顶':
        await _moveTop(id);
        break;
      case '登录':
        Navigator.pushNamed(
          context,
          RouteNames.sourceLogin,
          arguments: {'key': url, 'type': 'bookSource'},
        );
        break;
      case '搜索':
        Navigator.pushNamed(
          context,
          RouteNames.search,
          arguments: {'sourceId': id},
        );
        break;
      case '刷新':
        await _refreshKinds(id);
        break;
      case '删除':
        await _deleteSource(source);
        break;
    }
  }

  PopupMenuItem<String> _menuItem(String label, IconData icon) {
    return PopupMenuItem<String>(
      value: label,
      height: 40,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
  }

  Future<void> _moveTop(int id) async {
    try {
      await ExploreApi.moveTop(id);
      if (!mounted) return;
      _toast('已置顶');
      await _loadSources();
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('置顶失败：${e.message}');
    }
  }

  /// 刷新分类。
  ///
  /// 原版清的是书源侧的 exploreKinds 缓存；core 目前没有暴露这个方法，
  /// 这里退化成「丢掉本地缓存重新解析」，效果等价于重新拉一遍分类。
  Future<void> _refreshKinds(int id) async {
    setState(() => _kinds.remove(id));
    await _loadKinds(id);
  }

  Future<void> _deleteSource(Map<String, dynamic> source) async {
    final name = '${source['name'] ?? ''}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除'),
        content: Text('确定要删除 $name 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (!mounted || ok != true) return;
    try {
      await ExploreApi.delete(_idOf(source));
      if (!mounted) return;
      _toast('已删除');
      setState(() => _kinds.remove(_idOf(source)));
      await _loadSources();
    } on LegadoError catch (e) {
      if (!mounted) return;
      _toast('删除失败：${e.message}');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  static int _idOf(Map<String, dynamic> source) =>
      (source['id'] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('发现'),
            const SizedBox(width: 12),
            Expanded(child: _searchField()),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '分组',
            icon: const Icon(Icons.workspaces_outlined),
            onSelected: (group) {
              // 原版：点分组菜单 = 把搜索框设成 `group:xxx`。
              _ctrl.text = 'group:$group';
            },
            itemBuilder: (ctx) {
              final groups = _groups();
              if (groups.isEmpty) {
                return const [
                  PopupMenuItem<String>(
                    enabled: false,
                    child: Text('没有分组'),
                  ),
                ];
              }
              return [
                for (final group in groups)
                  PopupMenuItem<String>(
                    value: group,
                    child: Text(group),
                  ),
              ];
            },
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _searchField() {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: _ctrl,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: '筛选发现源',
          hintStyle: const TextStyle(fontSize: 13),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: _ctrl.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: _ctrl.clear,
                ),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_error != null) {
      return _emptyState(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        actionLabel: '重试',
        onAction: _loadSources,
      );
    }

    final sources = _visibleSources();
    if (sources.isEmpty) {
      return _emptyState(
        icon: Icons.explore_off_outlined,
        message: _sources.isEmpty ? '当前没有发现源！' : '没有匹配的书源',
        actionLabel: _sources.isEmpty ? '去书源管理' : null,
        onAction: _sources.isEmpty
            ? () => Navigator.pushNamed(context, RouteNames.sourceList)
            : null,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSources,
      child: ListView.builder(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        itemCount: sources.length,
        itemBuilder: (ctx, i) => _sourceTile(sources[i]),
      ),
    );
  }

  /// 单个书源卡片（对应原版 item_find_book.xml）。
  Widget _sourceTile(Map<String, dynamic> source) {
    final id = _idOf(source);
    final expanded = _expandedId == id;
    final kinds = _kinds[id] ?? const <Map<String, dynamic>>[];
    final loading = _loadingKinds.contains(id);
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        // 原版 bg_find_book_group：6dp 圆角 + 10% 黑。
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Builder(
              builder: (tileCtx) => InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _toggleExpand(source),
                onLongPress: () {
                  // 菜单锚在标题行上（InkWell 只有 onLongPress，
                  // 拿不到按下的精确位置，用标题行的左上角近似）。
                  final box = tileCtx.findRenderObject() as RenderBox?;
                  final origin =
                      box?.localToGlobal(Offset.zero) ?? Offset.zero;
                  _showSourceMenu(source, origin + const Offset(8, 20));
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${source['name'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (loading)
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: scheme.primary,
                          ),
                        ),
                      Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                child: _kindWrap(source, kinds),
              ),
          ],
        ),
      ),
    );
  }

  /// 分类胶囊（对应原版 item_fillet_text.xml）。
  Widget _kindWrap(
    Map<String, dynamic> source,
    List<Map<String, dynamic>> kinds,
  ) {
    if (kinds.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text('该源没有分类', style: TextStyle(fontSize: 12)),
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final kind in kinds)
          _KindChip(
            title: '${kind['title'] ?? ''}',
            onTap: () => _openKind(source, kind),
          ),
      ],
    );
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

/// 分类胶囊按钮。
///
/// 原版是 16dp 圆角 + 38% 灰底（`shape_fillet_btn`），文字 14sp。
class _KindChip extends StatelessWidget {
  const _KindChip({required this.title, required this.onTap});

  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.onSurface.withValues(alpha: 0.28),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
