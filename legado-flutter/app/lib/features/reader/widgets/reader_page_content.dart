import 'package:flutter/material.dart';

import '../../../core/image_url.dart';
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
  });

  final PageSlice page;
  final ReaderStyle style;
  final int pageCount;
  final String chapterTitle;

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
            width: width,
            height: block.imageHeight ?? style.fontSize * 8,
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
    required this.width,
    required this.height,
  });

  final String url;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final src = normalizeImageUrl(url);
    if (src == null) {
      return _placeholder(const Icon(Icons.image_not_supported_outlined, size: 22));
    }
    return SizedBox(
      width: width,
      height: height,
      child: Image.network(
        src,
        headers: imageHeaders(src),
        fit: BoxFit.contain,
        width: width,
        height: height,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        errorBuilder: (context, error, stack) =>
            _placeholder(const Icon(Icons.broken_image_outlined, size: 22)),
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
