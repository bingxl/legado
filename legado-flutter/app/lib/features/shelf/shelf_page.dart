import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/router/routes.dart';
import '../../core/widgets/book_cover.dart';
import 'shelf_api.dart';

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
            icon: Icon(
              _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
            ),
            onPressed: () => setState(() => _grid = !_grid),
          ),
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.pushNamed(context, RouteNames.search),
          ),
          IconButton(
            tooltip: '导出本分组书籍',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _exportGroup,
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
      floatingActionButton: FloatingActionButton(
        tooltip: '添加书籍',
        onPressed: _showAddSheet,
        child: const Icon(Icons.add),
      ),
    );
  }

  /// 书架「+」入口：本地 / 远程（WebDAV）/ 网址。
  Future<void> _showAddSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('添加本地书籍'),
              subtitle: const Text('从手机里选择 txt / epub 等文件'),
              onTap: () {
                Navigator.pop(ctx);
                _addLocalBooks();
              },
            ),
            ListTile(
              leading: const Icon(Icons.cloud_outlined),
              title: const Text('远程书籍'),
              subtitle: const Text('从 WebDAV 书库下载导入'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pushNamed(context, RouteNames.webdav);
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('添加网址'),
              subtitle: const Text('输入书籍详情页地址，自动匹配书源'),
              onTap: () {
                Navigator.pop(ctx);
                _addByUrl();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 添加本地书籍：选文件 → 读字节（兼容 Android content://）→ 写私有目录 → 导入。
  Future<void> _addLocalBooks() async {
    List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: '选择本地书籍',
        type: FileType.custom,
        allowedExtensions: const [
          'txt', 'epub', 'umd', 'pdf', 'mobi', 'azw3', 'azw',
        ],
      );
    } catch (e) {
      _snack('打开文件失败: $e');
      return;
    }
    if (!mounted || picked.isEmpty) return;

    final files = <({String name, List<int> bytes})>[];
    for (final file in picked) {
      try {
        files.add((name: file.name, bytes: await file.readAsBytes()));
      } catch (e) {
        _snack('读取 ${file.name} 失败: $e');
      }
    }
    if (files.isEmpty) return;
    _snack('正在导入 ${files.length} 本…');
    try {
      final result = await ShelfApi.importLocalBytes(
        files,
        _groupId,
        homeDir: LegadoClient.instance.homeDir,
      );
      final imported = (result['imported'] as List?)?.length ?? 0;
      final failedItems = (result['failed'] as List?) ?? const <Object>[];
      var message = '导入完成：成功 $imported 本，失败 ${failedItems.length} 本';
      // 只展示前两条原因：以前这里只报数量，用户看到「失败」却不知道为什么。
      final reasons = failedItems
          .whereType<Map>()
          .map((m) => '${m['reason'] ?? ''}')
          .where((s) => s.isNotEmpty)
          .take(2)
          .toList();
      if (reasons.isNotEmpty) message = '$message：${reasons.join('；')}';
      _snack(message);
      await _reload();
    } on LegadoError catch (e) {
      _snack('导入失败: ${e.message}');
    }
  }

  /// 添加网址：多行 URL → AddBookByUrl。
  Future<void> _addByUrl() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加书籍网址'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: controller,
            maxLines: 6,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: '每行一个书籍详情页地址',
              border: OutlineInputBorder(),
              helperText: '需先导入能匹配该网址的书源',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final urls = controller.text.trim();
    if (urls.isEmpty) {
      _snack('网址不能为空');
      return;
    }
    _snack('正在添加…');
    try {
      final result = await ShelfApi.addByUrls(urls, _groupId);
      final success = (result['success'] as List?)?.length ?? 0;
      final failed = (result['failed'] as List?)?.length ?? 0;
      _snack('添加完成：成功 $success 本，失败 $failed 本');
      await _reload();
    } on LegadoError catch (e) {
      _snack('添加失败: ${e.message}');
    }
  }

  // --------------------------------------------------------------------
  // 导出
  // --------------------------------------------------------------------

  /// 导出进度对话框：网络书要逐章抓取，可能耗时几十秒，必须给出反馈。
  /// 返回 notifier，调用方更新 .value 即可改文案；结束时 pop 掉。
  ValueNotifier<String> _showExportProgress(String initial) {
    final notifier = ValueNotifier<String>(initial);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope<Object?>(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: notifier,
            builder: (_, text, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text(text)),
              ],
            ),
          ),
        ),
      ),
    );
    return notifier;
  }

  void _closeExportProgress() {
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  /// 单本导出：从列表/网格的更多菜单进入。
  Future<void> _exportOne(Map<String, dynamic> book) async {
    final id = (book['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    final name = '${book['name'] ?? '书籍'}';
    final format = await _pickFormat();
    if (format == null) return;
    final dir = await _pickExportDir();
    if (dir == null) return;
    if (!mounted) return;

    final progress = _showExportProgress('正在导出《$name》…');
    try {
      final result = await ShelfApi.exportBook(id, format, dir);
      _closeExportProgress();
      _snack('已导出：${result['path'] ?? ''}');
    } on LegadoError catch (e) {
      _closeExportProgress();
      _snack('导出失败: ${e.message}');
    } finally {
      progress.dispose();
    }
  }

  /// 批量导出当前分组/全部的书架书籍。
  Future<void> _exportGroup() async {
    if (_books.isEmpty) {
      _snack('书架还是空的，没有可导出的书籍');
      return;
    }
    final format = await _pickFormat();
    if (format == null) return;

    // 批量导出让用户选一次目录，避免每本都弹系统对话框。
    final dir = await _pickExportDir();
    if (dir == null) return;
    if (!mounted) return;

    final total = _books.length;
    final progress = _showExportProgress('准备导出 $total 本书…');
    var ok = 0;
    final failed = <String>[];
    try {
      for (var i = 0; i < total; i++) {
        final book = _books[i];
        progress.value = '正在导出第 ${i + 1}/$total 本：《${book['name'] ?? ''}》';
        final id = (book['id'] as num?)?.toInt() ?? 0;
        if (id <= 0) continue;
        try {
          await ShelfApi.exportBook(id, format, dir);
          ok++;
        } on LegadoError catch (e) {
          failed.add('${book['name']}: ${e.message}');
        }
      }
      _closeExportProgress();
      var message = '导出完成：成功 $ok 本，失败 ${failed.length} 本';
      if (failed.isNotEmpty) message = '$message：${failed.first}';
      _snack(message);
    } finally {
      progress.dispose();
    }
  }

  /// 格式选择对话框：默认 EPUB；其余格式虽在内核里只是接口占位，
  /// 这里也列出来并明确标注「暂未实现」，避免用户点了之后毫无反馈。
  Future<String?> _pickFormat() async {
    List<Map<String, dynamic>> formats;
    try {
      formats = await ShelfApi.exportFormats();
    } on LegadoError catch (e) {
      _snack('读取导出格式失败: ${e.message}');
      return null;
    }
    if (formats.isEmpty) {
      _snack('内核未提供导出格式');
      return null;
    }
    if (!mounted) return null;
    // 已实现的排前面，EPUB 默认选中。
    formats.sort((a, b) {
      final ai = a['implemented'] == true ? 0 : 1;
      final bi = b['implemented'] == true ? 0 : 1;
      return ai.compareTo(bi);
    });
    var selected = formats.first['id'] ?? 'epub';
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('导出书籍'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in formats)
                  RadioListTile<String>(
                    value: '${f['id']}',
                    groupValue: selected,
                    title: Text('${f['name']}'),
                    subtitle: f['implemented'] == true
                        ? Text('保存到 .${f['extension']} 文件')
                        : const Text('接口已预留，暂未实现'),
                    enabled: f['implemented'] == true,
                    onChanged: f['implemented'] == true
                        ? (v) => setState(() => selected = v ?? selected)
                        : null,
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下一步'),
            ),
          ],
        ),
      ),
    );
    return picked == true ? selected : null;
  }

  /// 选导出目录；返回 null 表示用户取消。空串表示用内核默认目录。
  Future<String?> _pickExportDir() async {
    try {
      final dir = await FilePicker.getDirectoryPath(
        dialogTitle: '选择导出目录（取消则存到应用默认目录）',
      );
      return dir ?? '';
    } on Object {
      // 平台不支持目录选择（部分 Android 版本）时退回内核默认目录。
      return '';
    }
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
      itemBuilder: (_, i) => _BookTile(
        book: _books[i],
        onExport: () => _exportOne(_books[i]),
      ),
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
          title: Text(
            '${b['name'] ?? ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${b['author'] ?? ''} · ${b['durChapterTitle'] ?? '未读'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${b['percent'] ?? 0}%'),
              IconButton(
                tooltip: '导出此书',
                icon: const Icon(Icons.file_download_outlined, size: 20),
                onPressed: () => _exportOne(b),
              ),
            ],
          ),
          onTap: () => _open(b),
        );
      },
    );
  }

  Future<void> _open(Map<String, dynamic> book) async {
    final id = (book['id'] as num?)?.toInt() ?? 0;
    // 本地漫画要交给漫画阅读器逐页取图；网络漫画仍走文字阅读器的 images 渲染。
    var localComic = false;
    if ('${book['format'] ?? ''}' == 'comic') {
      try {
        localComic = await ShelfApi.isLocalBook(id);
      } on Object {
        // 判不出来就按网络漫画处理：文字阅读器至少能显示 images。
      }
    }
    if (!mounted) return;
    Navigator.pushNamed(
      context,
      RouteNames.reader,
      arguments: {
        'bookId': id,
        'bookName': book['name'],
        'kind': book['kind'],
        if (localComic) 'localComic': true,
      },
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, this.onExport});

  final Map<String, dynamic> book;
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final percent = (book['percent'] as num?)?.toInt() ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.pushNamed(
        context,
        RouteNames.reader,
        arguments: {
          'bookId': (book['id'] as num?)?.toInt() ?? 0,
          'bookName': book['name'],
          'kind': book['kind'],
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _Cover(book: book, size: double.infinity),
                if (onExport != null)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: FittedBox(
                        child: IconButton(
                          tooltip: '导出此书',
                          icon: const Icon(Icons.file_download_outlined),
                          color: Colors.white,
                          splashRadius: 18,
                          onPressed: onExport,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
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
              child: Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 封面：网络图 + 首字兜底（加载中/失败同样回落）。
class _Cover extends StatelessWidget {
  const _Cover({required this.book, required this.size});

  final Map<String, dynamic> book;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fill = size == double.infinity;
    return BookCover(
      name: '${book['name'] ?? '?'}',
      url: '${book['cover'] ?? ''}',
      width: fill ? null : size,
      height: fill ? null : size,
      radius: 6,
      fontSize: fill ? 28 : 16,
    );
  }
}
