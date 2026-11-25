import 'package:flutter/material.dart';

import '../../../core/widgets/cached_reader_image.dart';
import '../pagination.dart';
import '../reader_style.dart';

/// 单页正文渲染。
///
/// 关键点：这里**必须**用和分页时完全一致的宽度、字号、行高、段距，
/// 否则分页算出来的行数与实际渲染会对不上（表现为页尾被裁字或留白）。
/// 因此正文放在 `OverflowBox` 里按自然高度排版，再整体裁切——
/// 漏出的一两像素宁可裁掉，也不要触发 Column 的溢出黄条。
class ReaderPageContent extends StatelessWidget {
  const ReaderPageContent({
    super.key,
    required this.page,
    required this.style,
    required this.pageCount,
    required this.chapterTitle,
    this.onImageTapUp,
    this.onImageDoubleTap,
    this.localImagePath,
  });

  final PageSlice page;
  final ReaderStyle style;
  final int pageCount;
  final String chapterTitle;

  /// 点到正文插图时的单击：透传全局坐标，交给外层按 3×3 分区翻页。
  /// 不传则图片点击被吞掉（仅在没有翻页器的场合）。
  final ValueChanged<Offset>? onImageTapUp;

  /// 双击正文插图：打开全屏看图。
  final ValueChanged<String>? onImageDoubleTap;

  /// 插图命中内核图片缓存时的本地路径；未缓存传 null 走网络。
  final LocalImagePathResolver? localImagePath;

  @override
  Widget build(BuildContext context) {
    final background = style.background;
    final textStyle = style.textStyle(background.textColor);
    // 用 LayoutBuilder 拿真实版心宽度：分页时用的是同一个宽度，
    // 调用方不必再重复算一遍，也避免两处宽度不一致导致折行错位。
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - style.pagePadding.horizontal;
        return Padding(
          padding: style.pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: 0,
                    maxWidth: double.infinity,
                    minHeight: 0,
                    maxHeight: double.infinity,
                    child: SizedBox(
                      width: width,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: _blocks(textStyle, width),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: ReaderStyle.footerHeight,
                child: _footer(context, background),
              ),
            ],
          ),
        );
      },
    );
  }

  List<Widget> _blocks(TextStyle textStyle, double width) {
    final children = <Widget>[];
    for (final block in page.blocks) {
      if (block.isImage) {
        children.add(
          _InlineImage(
            url: block.imageUrl!,
            localPath: localImagePath?.call(block.imageUrl!),
            width: width,
            height: block.imageHeight ?? style.fontSize * 8,
            onTapUp: onImageTapUp == null
                ? null
                : (details) => onImageTapUp!(details.globalPosition),
            onDoubleTap: onImageDoubleTap == null
                ? null
                : () => onImageDoubleTap!(block.imageUrl!),
          ),
        );
      } else {
        children.add(
          Text(
            block.text,
            style: textStyle,
            // 与分页测量用同一个对齐方式（见 ReaderTypography.justify）。
            textAlign: style.align,
            // 阅读器有自己的字号设置，不再叠加系统字体缩放，否则分页必然错位。
            textScaler: TextScaler.noScaling,
          ),
        );
      }
      if (block.endsParagraph) {
        children.add(SizedBox(height: style.paragraphSpacing));
      }
    }
    return children;
  }

  Widget _footer(BuildContext context, ReaderBackground background) {
    final muted = background.textColor.withValues(alpha: 0.42);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(
            chapterTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: muted),
            textScaler: TextScaler.noScaling,
          ),
        ),
        if (style.showPageNumber)
          Text(
            '${page.index + 1}/$pageCount',
            style: TextStyle(fontSize: 11, color: muted),
            textScaler: TextScaler.noScaling,
          ),
      ],
    );
  }
}

/// 正文中的内联图片。
///
/// 高度由分页阶段定死，这里只负责按同一高度显示；失败时给一个明确占位，
/// 不能让一张挂掉的图片把整段正文从版面上抹掉。
class _InlineImage extends StatelessWidget {
  const _InlineImage({
    required this.url,
    this.localPath,
    required this.width,
    required this.height,
    this.onTapUp,
    this.onDoubleTap,
  });

  final String url;
  final String? localPath;
  final double width;
  final double height;
  final ValueChanged<TapUpDetails>? onTapUp;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    // 同一 GestureDetector 内声明 onTapUp + onDoubleTap，Flutter 会先判双击：
    // 双击时只走 onDoubleTap（打开看图），单击仍走 onTapUp（透传给外层翻页）。
    // 若分开成内外两层 detector，外层 Tap 会先认领，双击永远触发不到。
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: onTapUp,
      onDoubleTap: onDoubleTap,
      child: SizedBox(
        width: width,
        height: height,
        child: CachedReaderImage(
          url: url,
          localPath: localPath,
          fit: BoxFit.contain,
          width: width,
          height: height,
          filterQuality: FilterQuality.high,
          errorBuilder: (context, error, stack) =>
              _placeholder(const Icon(Icons.broken_image_outlined, size: 22)),
        ),
      ),
    );
  }

  Widget _placeholder(Widget icon) => SizedBox(
    width: width,
    height: height,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [icon, const SizedBox(height: 4), const Text('图片加载失败')],
      ),
    ),
  );
}
