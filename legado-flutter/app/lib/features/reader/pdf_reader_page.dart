import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/bridge/api.dart';
import '../../core/bridge/legado_client.dart';
import '../../core/widgets/copy_links.dart';
import 'progress.dart';
import 'pdf_channel.dart';
import 'widgets/error_retry_view.dart';
import 'widgets/toc_sheet_scaffold.dart';
import 'widgets/progress_slider.dart';

/// 与 core 的 `PdfParser.pagesPerChapter`（及原版 PdfFile.PAGE_SIZE）一致。
const kPdfPagesPerChapter = 10;

/// PDF 阅读页。
///
/// 与原版 Kotlin `PdfFile` 的分段语义一致：core 把整本按每 10 页切成「分段」
/// 章节存目录，这里按**页**翻，进度落回「页索引 ÷ 10」对应的章节。
/// 页码以平台渲染器返回的真实页数为准——core 的纯字节探测可能不准，
/// 发现不符时用 `Reader.SyncOutline` 回写目录。
class PdfReaderPage extends StatefulWidget {
  const PdfReaderPage({super.key, required this.bookId, this.bookName});

  final int bookId;
  final String? bookName;

  static Widget fromRouteArguments(Object? args) {
    final map = args is Map ? args : const <String, Object?>{};
    return PdfReaderPage(
      bookId: (map['bookId'] as num?)?.toInt() ?? 0,
      bookName: map['bookName'] as String?,
    );
  }

  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  String _path = '';
  int _pageCount = 0;
  int _pageIndex = 0;
  Uint8List? _image;
  List<Map<String, dynamic>> _chapters = const [];
  bool _loading = true;
  String? _error;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    unawaited(_load());
  }

  @override
  void dispose() {
    if (_path.isNotEmpty) {
      unawaited(_saveProgress());
      unawaited(PdfChannel.close(_path));
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await LegadoClient.instance.call(
        pdfGetLocalFile,
        [widget.bookId],
      );
      final path = '$raw';
      if (path.isEmpty) {
        throw const PdfRenderException('这本书不是本地 PDF');
      }
      final count = await PdfChannel.pageCount(path);
      if (count < 1) {
        throw const PdfRenderException('PDF 打不开（可能加密或已损坏）');
      }

      // 续读：core 记的是「分段号 + 段内页偏移」，换回全局页索引。
      //
      // `chapterPos` 对 PDF 就是段内第几页（与漫画章把它当图片序号同理）：
      // 只按 `chapter * 10` 恢复会让用户永远回到这一段的第 1 页。
      var initial = 0;
      final progress = await LegadoClient.instance.call(
        Api.readerGetProgress,
        [widget.bookId],
      );
      if (progress is Map) {
        final chapter = (progress['chapterIndex'] as num?)?.toInt() ?? 0;
        final offset = (progress['chapterPos'] as num?)?.toInt() ?? 0;
        if (chapter > 0 || offset > 0) {
          final start = chapter * kPdfPagesPerChapter;
          final sectionLength =
              (count - start).clamp(0, kPdfPagesPerChapter);
          initial = start +
              (sectionLength <= 0 ? 0 : offset.clamp(0, sectionLength - 1));
        }
      }
      if (initial < 0 || initial >= count) initial = 0;

      final toc = await LegadoClient.instance.call(
        Api.readerGetChapters,
        [widget.bookId],
      );
      final chapters = toc is List
          ? toc
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList(growable: false)
          : <Map<String, dynamic>>[];

      if (!mounted) return;
      setState(() {
        _path = path;
        _pageCount = count;
        _pageIndex = initial;
        _chapters = chapters;
      });

      // 页数探测不准时重建目录，保证目录项数与真实分段一致。
      final expected = (count + kPdfPagesPerChapter - 1) ~/ kPdfPagesPerChapter;
      if (chapters.length != expected) {
        await _syncOutline(count);
      }
      await _render();
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _syncOutline(int count) async {
    final items = <Map<String, Object?>>[];
    for (var start = 0, i = 0; start < count; start += kPdfPagesPerChapter, i++) {
      items.add(<String, Object?>{
        'title': '分段_${i + 1}',
        'url': '$_path#pdf-$start',
        'isVolume': false,
      });
    }
    await LegadoClient.instance.call(pdfSyncOutline, [widget.bookId, items]);
    if (!mounted) return;
    setState(() => _chapters = items.cast<Map<String, dynamic>>());
  }

  int _targetWidth() {
    final media = MediaQuery.of(context);
    return (media.size.width * media.devicePixelRatio).round().clamp(320, 2560);
  }

  Future<void> _render() async {
    if (_path.isEmpty || _pageCount < 1) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await PdfChannel.renderPage(
        _path,
        _pageIndex,
        _targetWidth(),
      );
      if (!mounted) return;
      setState(() {
        _image = bytes;
        _loading = false;
      });
      unawaited(_saveProgress());
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 当前 PDF 分段（每 10 页一段，与 core 的章节切分一致）。
  ({int index, int start, int count}) get _section {
    final index = (_pageIndex ~/ kPdfPagesPerChapter).clamp(0, _sectionCount - 1);
    final start = index * kPdfPagesPerChapter;
    return (index: index, start: start, count: _sectionLength(index));
  }

  int get _sectionCount =>
      (_pageCount + kPdfPagesPerChapter - 1) ~/ kPdfPagesPerChapter;

  int _sectionLength(int section) =>
      (_pageCount - section * kPdfPagesPerChapter).clamp(0, kPdfPagesPerChapter);

  Future<void> _saveProgress() async {
    if (_path.isEmpty || _pageCount < 1) return;
    final section = _section;
    try {
      await LegadoClient.instance.call(Api.readerSaveProgress, [
        widget.bookId,
        section.index,
        '分段_${section.index + 1}',
        // 段内页偏移：下次打开要落回同一页，不能恒传 0。
        (_pageIndex - section.start).clamp(0, section.count - 1),
        readPercentForIndex(_pageIndex - section.start, section.count),
      ]);
    } on Object {
      // 落盘失败不能打断阅读。
    }
  }

  void _go(int page) {
    final target = page.clamp(0, _pageCount - 1);
    if (_pageCount < 1 || target == _pageIndex) return;
    setState(() => _pageIndex = target);
    unawaited(_render());
  }

  Future<void> _openToc() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _PdfTocSheet(
        chapters: _chapters,
        currentPage: _pageIndex,
        onTap: (i) {
          Navigator.of(ctx).pop();
          _go(i * kPdfPagesPerChapter);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1B1B1B),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.bookName ?? 'PDF 阅读'),
            Text(
              _pageCount > 0 ? '${_pageIndex + 1} / $_pageCount 页' : 'PDF',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt_outlined),
            tooltip: '目录',
            onPressed: _chapters.isEmpty ? null : _openToc,
          ),
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: '复制地址',
            onPressed: () =>
                showCopyLinkSheet(context, bookId: widget.bookId, title: '复制地址'),
          ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _pageCount > 1 ? _bottomBar() : null,
    );
  }

  Widget _body() {
    if (_image == null) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_error != null) {
        return ErrorRetryView(message: _error!, icon: Icons.error_outline, onRetry: _load);
      }
      return const Center(
        child: Text('暂无页面', style: TextStyle(color: Colors.white70)),
      );
    }

    // Listener 不参与手势竞技场，点左右边缘翻页不会和 InteractiveViewer
    // 的双击缩放/拖拽抢事件。
    return Listener(
      onPointerDown: (event) {
        final width = MediaQuery.sizeOf(context).width;
        if (event.localPosition.dx < width * 0.18) {
          _go(_pageIndex - 1);
        } else if (event.localPosition.dx > width * 0.82) {
          _go(_pageIndex + 1);
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Image.memory(
                _image!,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
          if (_loading)
            const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(minHeight: 2),
            ),
        ],
      ),
    );
  }

  Widget _bottomBar() {
    // 进度条只在本分段（10 页）内滑动，对齐文字/漫画的章内口径；
    // 左右按钮仍可逐页跨分段，不把「换段」藏进进度条。
    final section = _section;
    final progress = ReaderProgress(
      index: _pageIndex - section.start,
      count: section.count,
    );
    return Container(
      color: const Color(0xFF232323),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: _pageIndex > 0 ? () => _go(_pageIndex - 1) : null,
          ),
          Expanded(
            child: ReaderProgressSlider(
              progress: progress,
              enabled: progress.count > 0,
              onSeek: (percent) =>
                  _go(section.start + indexForReadPercent(percent, section.count)),
              themeData: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _pageIndex < _pageCount - 1
                ? () => _go(_pageIndex + 1)
                : null,
          ),
        ],
      ),
    );
  }
}

/// PDF 目录面板：外壳与文字目录共用 TocSheetScaffold，只有列表项不同。
class _PdfTocSheet extends StatelessWidget {
  const _PdfTocSheet({
    required this.chapters,
    required this.currentPage,
    required this.onTap,
  });

  final List<Map<String, dynamic>> chapters;
  final int currentPage;
  final void Function(int index) onTap;

  Widget _buildItem(BuildContext context, int i) {
    final scheme = Theme.of(context).colorScheme;
    final pageStart = i * kPdfPagesPerChapter;
    final pageEnd = pageStart + kPdfPagesPerChapter;
    final current = currentPage >= pageStart && currentPage < pageEnd;
    return ListTile(
      title: Text('${chapters[i]['title'] ?? '分段_${i + 1}'}'),
      subtitle: Text('第 ${pageStart + 1} 页起'),
      onTap: () => onTap(i),
      trailing: current
          ? Icon(Icons.play_arrow, size: 16, color: scheme.primary)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return TocSheetScaffold(
      countLabel: '共 ${chapters.length} 段',
      itemCount: chapters.length,
      itemBuilder: _buildItem,
    );
  }
}
