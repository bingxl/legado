import 'package:flutter/material.dart';

import '../../../core/image_url.dart';

/// 看图页图片解码失败时的统一占位（本地漫画、网络漫画、正文插图共用）。
const Widget viewerImageErrorPlaceholder = Center(
  child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 40),
);

/// 全屏看图页：阅读正文/漫画里双击图片后进入。
///
/// 只负责「左右滑切换 + 捏合缩放 + 双击切 1x/2.5x + 页码/关闭」，
/// 每张图怎么加载由 [imageBuilder] 决定 —— 网络图带防盗链头、本地图走异步解压，
/// 三种来源（正文插图 / 网络漫画 / 本地漫画）共用这一个组件。
///
/// 手势约定：
/// - 未放大时左右滑切换图片；放大后拖动平移、捏合缩放。
/// - 双击在 1x 与 2.5x 间切换；单击不关闭（返回用系统返回键或顶栏按钮），
///   避免与阅读页「单击翻页」的肌肉记忆打架。
class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({
    super.key,
    required this.count,
    required this.initialIndex,
    required this.imageBuilder,
    this.title,
  });

  /// 可查看的图片总数。
  final int count;

  /// 进入时定位到哪一张。
  final int initialIndex;

  /// 构建第 [index] 张图片（返回 Image / FutureBuilder 均可）。
  final IndexedWidgetBuilder imageBuilder;

  final String? title;

  /// 打开看图页。
  static Future<void> open(
    BuildContext context, {
    required int count,
    required int initialIndex,
    required IndexedWidgetBuilder imageBuilder,
    String? title,
  }) {
    if (count <= 0) return Future.value();
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ImageViewerPage(
          count: count,
          initialIndex: initialIndex.clamp(0, count - 1),
          imageBuilder: imageBuilder,
          title: title,
        ),
      ),
    );
  }

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

/// 把一组原始图片地址归一化，并定位 [tapped] 在其中的位置。
///
/// - 无效地址（相对路径 / 空串）被剔除，返回的列表可直接交给 Image.network；
/// - [tapped] 归一化后在列表里找下标，找不到（比如它是从 HTML 里另取的一份）就回退到 0；
/// - 返回 null 表示整组没有可用地址，调用方应放弃打开看图。
///
/// 抽成纯函数是为了单测：双击定位错误会让「点第 3 张却打开第 1 张」这类问题很难在 UI 上发现。
ViewerSources? resolveViewerSources(List<String> urls, String tapped) {
  final normalized = <String>[];
  for (final url in urls) {
    final src = normalizeImageUrl(url);
    if (src != null) normalized.add(src);
  }
  if (normalized.isEmpty) return null;
  final tappedSrc = normalizeImageUrl(tapped) ?? tapped;
  final index = normalized.indexOf(tappedSrc);
  return ViewerSources(
    urls: List<String>.unmodifiable(normalized),
    index: index < 0 ? 0 : index,
  );
}

/// 看图页的图源列表与初始下标。
class ViewerSources {
  const ViewerSources({required this.urls, required this.index});

  final List<String> urls;
  final int index;
}

class _ImageViewerPageState extends State<ImageViewerPage>
    with SingleTickerProviderStateMixin {
  static const double _zoomScale = 2.5;

  late final PageController _page = PageController(
    initialPage: widget.initialIndex,
  );
  final TransformationController _transform = TransformationController();

  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(() {
      _transform.value = _zoomTween.evaluate(_zoom);
    });
  Matrix4Tween _zoomTween = Matrix4Tween(
    begin: Matrix4.identity(),
    end: Matrix4.identity(),
  );

  int _index = 0;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _transform.addListener(_onTransformChanged);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransformChanged);
    _transform.dispose();
    _zoom.dispose();
    _page.dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.05;
    if (zoomed != _zoomed && mounted) setState(() => _zoomed = zoomed);
  }

  /// 双击：1x ↔ 2.5x。用 Matrix4Tween 动画，缩放中心固定在图片中心附近。
  void _toggleZoom() {
    final target = _zoomed
        ? Matrix4.identity()
        : Matrix4.diagonal3Values(_zoomScale, _zoomScale, 1);
    _zoomTween = Matrix4Tween(begin: _transform.value, end: target);
    _zoom.forward(from: 0);
  }

  void _onPageChanged(int index) {
    // 换图时复位缩放，否则上一张的放大状态会带到下一张。
    _zoom.stop();
    _transform.value = Matrix4.identity();
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title ?? '图片'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '${_index + 1}/${widget.count}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _page,
        itemCount: widget.count,
        onPageChanged: _onPageChanged,
        // 放大后禁用切页，让 InteractiveViewer 独占拖动做平移。
        physics: _zoomed
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        itemBuilder: (context, index) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 5,
            // 未放大时把拖动让给 PageView 切图；放大后才允许平移看图。
            panEnabled: _zoomed,
            child: Center(child: widget.imageBuilder(context, index)),
          ),
        ),
      ),
    );
  }
}
