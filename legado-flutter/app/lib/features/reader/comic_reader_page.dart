import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/bridge/legado_client.dart';
import '../../core/widgets/copy_links.dart';

/// 本地漫画阅读器（zip / cbz）。
///
/// 与文字阅读器分家的理由：漫画的"章节"是页，一份 zip 里有几百页，
/// 走 `Reader.GetContent` 会把整页 bitmap 塞进 JSON 控制面（base64 膨胀 33%），
/// 一次翻页就是几 MB。这里改成 `Reader.GetLocalPage`：core 解压一页到磁盘，
/// UI 拿到路径用 `Image.file` 读，相邻页由 Flutter 的图片缓存兜住。
class ComicReaderPage extends StatefulWidget {
  const ComicReaderPage({
    super.key,
    required this.bookId,
    this.bookName,
    this.initialIndex = -1,
  });

  final int bookId;
  final String? bookName;

  /// <0 表示按进度恢复。
  final int initialIndex;

  static Widget fromRouteArguments(Object? arguments) {
    final args = arguments is Map ? arguments : const {};
    return ComicReaderPage(
      bookId: (args['bookId'] as num?)?.toInt() ?? 0,
      bookName: args['bookName'] as String?,
      initialIndex: (args['chapterIndex'] as num?)?.toInt() ?? -1,
    );
  }

  @override
  State<ComicReaderPage> createState() => _ComicReaderPageState();
}

class _ComicReaderPageState extends State<ComicReaderPage> {
  static const String _pageMethod = 'Reader.GetLocalPage';
  static const String _chaptersMethod = 'Reader.GetChapters';
  static const String _progressMethod = 'Reader.GetProgress';
  static const String _saveProgressMethod = 'Reader.SaveProgress';

  PageController? _controller;
  final Map<int, Future<Map<String, dynamic>>> _cache = <int, Future<Map<String, dynamic>>>{};

  int _pageCount = 0;
  int _index = 0;
  bool _loading = true;
  String? _error;

  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = LegadoClient.instance;
    try {
      final chapters = await client.callList(_chaptersMethod, [widget.bookId]);
      var start = widget.initialIndex;
      if (start < 0) {
        final progress = await client.call(_progressMethod, [widget.bookId]);
        start = progress is Map
            ? (progress['chapterIndex'] as num?)?.toInt() ?? 0
            : 0;
      }
      if (!mounted) return;
      final count = chapters.length;
      final index = count == 0 ? 0 : start.clamp(0, count - 1);
      _controller?.dispose();
      _controller = PageController(initialPage: index);
      setState(() {
        _pageCount = count;
        _index = index;
        _loading = false;
      });
      if (count == 0) {
        setState(() => _error = '这本漫画没有解析出页面');
      }
    } on LegadoError catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.message;
      });
    }
  }

  Future<Map<String, dynamic>> _page(int index) {
    return _cache.putIfAbsent(index, () async {
      final data = await LegadoClient.instance.call(_pageMethod, [
        widget.bookId,
        index,
      ]);
      return (data as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    });
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    // 翻页动画期间会连续触发，防抖后再落盘，避免每页一次写库。
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      final total = _pageCount;
      final percent = total <= 1 ? 100.0 : (index * 100 / (total - 1));
      LegadoClient.instance
          .call(_saveProgressMethod, [
            widget.bookId,
            index,
            '第 ${index + 1} 页',
            0,
            percent,
          ])
          .catchError((Object _) => null);
    });
  }

  void _jumpTo(int index) {
    final controller = _controller;
    if (controller == null || _pageCount == 0) return;
    controller.jumpToPage(index.clamp(0, _pageCount - 1));
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.bookName?.trim().isNotEmpty == true
        ? widget.bookName!
        : '漫画';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.85),
        foregroundColor: Colors.white,
        title: Text(
          '$title  ${_pageCount == 0 ? '' : '${_index + 1}/$_pageCount'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: '跳到指定页',
            icon: const Icon(Icons.pin_outlined),
            onPressed: _pageCount == 0 ? null : _showJumpDialog,
          ),
          IconButton(
            tooltip: '复制地址',
            icon: const Icon(Icons.link),
            onPressed: () =>
                showCopyLinkSheet(context, bookId: widget.bookId, title: '复制地址'),
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image_not_supported_outlined,
                  color: Colors.white54, size: 40),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: _pageCount,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) => _ComicPage(
              future: _page(index),
              onRetry: () {
                setState(() => _cache.remove(index));
              },
            ),
          ),
        ),
        if (_pageCount > 1) _bottomBar(),
      ],
    );
  }

  Widget _bottomBar() {
    return Container(
      color: Colors.black.withValues(alpha: 0.85),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Text(
            '${_index + 1}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: _index.toDouble(),
              min: 0,
              max: (_pageCount - 1).toDouble(),
              // 页数少于一屏时 Slider 的 divisions 必须 > 0。
              divisions: _pageCount > 1 ? _pageCount - 1 : null,
              onChanged: (value) => _jumpTo(value.round()),
            ),
          ),
          Text(
            '$_pageCount',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _showJumpDialog() async {
    final controller = TextEditingController(text: '${_index + 1}');
    final page = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳到指定页'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '页码（1 ~ $_pageCount）',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (value) =>
              Navigator.of(ctx).pop(int.tryParse(value.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(ctx).pop(int.tryParse(controller.text.trim())),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (page != null) _jumpTo(page - 1);
  }
}

/// 单页图片：失败时给出重试，不把整章拖垮。
class _ComicPage extends StatelessWidget {
  const _ComicPage({required this.future, required this.onRetry});

  final Future<Map<String, dynamic>> future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _error('${snapshot.error}', onRetry);
        }
        final path = '${snapshot.data?['path'] ?? ''}';
        if (path.isEmpty) return _error('这一页没有图片', onRetry);
        final file = File(path);
        return InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(
            child: Image.file(
              file,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _error('图片读取失败', onRetry),
            ),
          ),
        );
      },
    );
  }

  Widget _error(String message, VoidCallback onRetry) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 36),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}
