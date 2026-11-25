import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/widgets/copy_links.dart';
import 'progress.dart';
import 'widgets/error_retry_view.dart';
import 'widgets/image_viewer_page.dart';
import 'widgets/progress_slider.dart';

/// 内核把 zip 的每页存成一章，直接拿章节数当进度条总数会变成「整本几百页」
/// 一根条，和文字/网络漫画的章内口径不一致。这里在 UI 层按每 50 页切一段，
/// 滑动只在当前段内；页码输入框仍可跳到整本的任意页。
const kComicPagesPerSection = 50;

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
    // 防抖未落地就退出时补一次保存，否则最后 600ms 翻的页会丢。
    unawaited(_saveProgress(_index));
    _saveTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// 当前 50 页分段（UI 层的「章」，core 仍按每页一章存进度）。
  ({int index, int start, int count}) get _section {
    final index = (_index ~/ kComicPagesPerSection).clamp(
      0,
      (_pageCount == 0 ? 1 : (_pageCount + kComicPagesPerSection - 1) ~/ kComicPagesPerSection) - 1,
    );
    final start = index * kComicPagesPerSection;
    return (
      index: index,
      start: start,
      count: (_pageCount - start).clamp(0, kComicPagesPerSection),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = LegadoClient.instance;
    try {
      final chapters = await client.callList(Api.readerGetChapters, [widget.bookId]);
      var start = widget.initialIndex;
      if (start < 0) {
        final progress = await client.call(Api.readerGetProgress, [widget.bookId]);
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
      final data = await LegadoClient.instance.call(Api.readerGetLocalPage, [
        widget.bookId,
        index,
      ]);
      return (data as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    });
  }

  /// 双击某页 → 全屏看图。看图页按 index 复用 _page() 的解压 Future，
  /// 左右滑时相邻页若已缓存会秒开，未缓存则短暂等待解压。
  void _openViewer(int index) {
    if (_pageCount <= 0) return;
    unawaited(
      ImageViewerPage.open(
        context,
        count: _pageCount,
        initialIndex: index,
        title: widget.bookName ?? '漫画',
        imageBuilder: (ctx, i) => FutureBuilder<Map<String, dynamic>>(
          future: _page(i),
          builder: (context, snapshot) {
            final path = '${snapshot.data?['path'] ?? ''}';
            if (snapshot.connectionState != ConnectionState.done || path.isEmpty) {
              return const Center(child: CircularProgressIndicator(color: Colors.white70));
            }
            return Image.file(
              File(path),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => viewerImageErrorPlaceholder,
            );
          },
        ),
      ),
    );
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    // 翻页动画期间会连续触发，防抖后再落盘，避免每页一次写库。
    _saveTimer?.cancel();
    _saveTimer = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_saveProgress(index)),
    );
  }

  /// core 按「每页一章」记录本地漫画，所以 chapterIndex 用整本页索引，
  /// scrollPercent 用原版同样的「当前项 / 总数」口径（末页 100%）。
  Future<void> _saveProgress(int index) async {
    if (_pageCount <= 0) return;
    try {
      await LegadoClient.instance.call(Api.readerSaveProgress, [
        widget.bookId,
        index,
        '第 ${index + 1} 页',
        0,
        readPercentForIndex(index, _pageCount) * 100,
      ]);
    } on Object {
      // 落盘失败不能打断看图。
    }
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
      return ErrorRetryView(
        message: error,
        icon: Icons.image_not_supported_outlined,
        color: Colors.white70,
        onRetry: _load,
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
              onDoubleTap: () => _openViewer(index),
            ),
          ),
        ),
        if (_pageCount > 1) _bottomBar(),
      ],
    );
  }

  Widget _bottomBar() {
    // 与文字/网络漫画一致：滑动只在本段（50 页）内，不跨整本。
    // 标题栏仍显示整本页码，跳页对话框也能直接输整本页码。
    final section = _section;
    final progress = ReaderProgress(
      index: _index - section.start,
      count: section.count,
    );
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
            child: ReaderProgressSlider(
              progress: progress,
              enabled: progress.count > 0,
              onSeek: (percent) =>
                  _jumpTo(section.start + indexForReadPercent(percent, section.count)),
              themeData: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
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
  const _ComicPage({
    required this.future,
    required this.onRetry,
    this.onDoubleTap,
  });

  final Future<Map<String, dynamic>> future;
  final VoidCallback onRetry;
  final VoidCallback? onDoubleTap;

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
        // InteractiveViewer 自带捏合缩放；外层再套一个只认双击的 detector，
        // 双击进全屏看图（左右滑看相邻页）。单击不声明，留给内层拖拽。
        return GestureDetector(
          onDoubleTap: onDoubleTap,
          child: InteractiveViewer(
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
