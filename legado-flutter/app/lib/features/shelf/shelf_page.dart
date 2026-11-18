import 'package:flutter/material.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';

/// 书架页（对应原版 `ui/main/bookshelf/BookShelfFragment`）。
///
/// 数据全部来自 core：分组、书籍、阅读进度都是 `Shelf.*` 方法返回的 dto，
/// Dart 侧只保留「当前选中的分组」这类渲染临时状态（MODULE-PLAN §1.1）。
class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<Map<String, dynamic>> _groups = const [];
  List<Map<String, dynamic>> _books = const [];
  int _groupId = 0;
  bool _loading = true;
  String? _error;
  bool _grid = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = LegadoClient.instance;
      final groups = await client.callList(Api.shelfListGroups);
      final books = await client.callList(Api.shelfListBooks, [_groupId]);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _books = books;
        _loading = false;
      });
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '${e.code}: ${e.message}';
        _loading = false;
      });
    }
  }

  Future<void> _selectGroup(int id) async {
    if (_groupId == id) return;
    _groupId = id;
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书架'),
        actions: [
          IconButton(
            tooltip: _grid ? '切换列表' : '切换网格',
            icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, RouteNames.search),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
        ],
      ),
      body: Column(
        children: [
          _groupBar(),
          const Divider(height: 0.6),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _groupBar() {
    final items = <Map<String, dynamic>>[
      {'id': 0, 'name': '全部'},
      ..._groups,
    ];
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final g = items[i];
          final id = (g['id'] as num?)?.toInt() ?? 0;
          final selected = id == _groupId;
          return ChoiceChip(
            label: Text('${g['name'] ?? ''}'),
            selected: selected,
            onSelected: (_) => _selectGroup(id),
          );
        },
      ),
    );
  }

  Widget _content() {
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
              FilledButton(onPressed: _reload, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_books.isEmpty) {
      return const Center(child: Text('书架还是空的，去「发现」找一本吧'));
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: _grid ? _gridView() : _listView(),
    );
  }

  Widget _gridView() {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 132,
        childAspectRatio: 0.58,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _books.length,
      itemBuilder: (_, i) => _BookTile(book: _books[i]),
    );
  }

  Widget _listView() {
    return ListView.separated(
      itemCount: _books.length,
      separatorBuilder: (_, _) => const Divider(height: 0.6),
      itemBuilder: (_, i) {
        final b = _books[i];
        return ListTile(
          leading: _Cover(book: b, size: 40),
          title: Text('${b['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${b['author'] ?? ''} · ${b['durChapterTitle'] ?? '未读'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text('${b['percent'] ?? 0}%'),
          onTap: () => _open(b),
        );
      },
    );
  }

  void _open(Map<String, dynamic> book) {
    final id = (book['id'] as num?)?.toInt() ?? 0;
    Navigator.pushNamed(
      context,
      RouteNames.reader,
      arguments: {'bookId': id, 'bookName': book['name']},
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});

  final Map<String, dynamic> book;

  @override
  Widget build(BuildContext context) {
    final percent = (book['percent'] as num?)?.toInt() ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.pushNamed(
        context,
        RouteNames.reader,
        arguments: {'bookId': (book['id'] as num?)?.toInt() ?? 0, 'bookName': book['name']},
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _Cover(book: book, size: double.infinity)),
          const SizedBox(height: 6),
          Text(
            '${book['name'] ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          if (percent > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('$percent%', style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.outline)),
            ),
        ],
      ),
    );
  }
}

/// 封面：core 的 `/img/` 数据面还没接入，先用首字占位。
class _Cover extends StatelessWidget {
  const _Cover({required this.book, required this.size});

  final Map<String, dynamic> book;
  final double size;

  @override
  Widget build(BuildContext context) {
    final name = '${book['name'] ?? '?'}';
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size == double.infinity ? null : size,
      height: size == double.infinity ? null : size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        color: scheme.primaryContainer,
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : String.fromCharCode(name.runes.first),
        style: TextStyle(
          fontSize: size == double.infinity ? 28 : 16,
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
