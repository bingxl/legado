import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 分页用的排版参数（与 `ReaderStyle` 解耦，方便单测里构造任意值）。
@immutable
class ReaderTypography {
  const ReaderTypography({
    this.fontSize = 20,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 10,
    this.indent = '　　',
  });

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final String indent;

  /// 空段落占用的高度：按一整行算，保证「空行」在版面上真的空出一行。
  double get blankLineHeight => fontSize * lineHeight;

  ReaderTypography copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    String? indent,
  }) {
    return ReaderTypography(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      indent: indent ?? this.indent,
    );
  }
}

/// 一页里的一个文本块（同一段落被分页切开时会有多个块）。
@immutable
class PageBlock {
  const PageBlock({
    required this.paragraphIndex,
    required this.text,
    required this.endsParagraph,
    required this.offset,
  });

  /// 段落下标，渲染时同段块之间不加段距。
  final int paragraphIndex;

  /// 本块文字（已含首行缩进前缀）；可跨多行。
  final String text;

  /// 是否是该段的最后一块——渲染时在块后留出段间距。
  final bool endsParagraph;

  /// 本块首字符在整章纯文本中的偏移，用于恢复阅读进度。
  final int offset;
}

/// 一页。
@immutable
class PageSlice {
  const PageSlice({
    required this.index,
    required this.blocks,
    required this.startOffset,
  });

  final int index;
  final List<PageBlock> blocks;

  /// 本页第一个字符在整章纯文本中的偏移。
  final int startOffset;

  bool get isEmpty => blocks.isEmpty;

  /// 本页纯文本（块之间用换行连接），用于朗读分段。
  String get text => blocks.map((b) => b.text).join('\n');
}

/// 纯函数分页。
///
/// 输入段落 + 版心 + 排版参数，输出页列表。不碰文件、不发网络、不读 context，
/// 所以可以直接在单测里断言；也因为无副作用，重新分页（改字号/窗口缩放）时
/// 只要拿当前页的 [PageSlice.startOffset] 重新算一遍就能停在原处。
///
/// 实现方式：逐段用 [TextPainter] 排版，再用 `getLineBoundary` 取出每一显示行，
/// 按行高贪心装页。之所以按行而不是按字符二分，是因为中英混排、两端对齐下
/// 行高与断行位置只有排版引擎说了算，自己算必然和渲染结果对不上。
List<PageSlice> paginate({
  required List<String> paragraphs,
  required Size pageSize,
  required ReaderTypography typography,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (paragraphs.isEmpty || pageSize.width <= 0 || pageSize.height <= 0) {
    return const [PageSlice(index: 0, blocks: [], startOffset: 0)];
  }

  final style = TextStyle(
    fontSize: typography.fontSize,
    height: typography.lineHeight,
  );
  final builder = _PageBuilder(pageHeight: pageSize.height);
  final indentLength = typography.indent.length;
  var chapterOffset = 0;

  for (var i = 0; i < paragraphs.length; i++) {
    final raw = paragraphs[i];
    final paragraphStart = chapterOffset;
    // 段与段之间在纯文本里用 '\n' 分隔，偏移量按此累计。
    chapterOffset += raw.length + 1;

    final display = raw.trim().isEmpty ? '' : '${typography.indent}$raw';
    final lines = _measureParagraph(
      display: display,
      style: style,
      maxWidth: pageSize.width,
      textScaler: textScaler,
      typography: typography,
      isBlank: display.isEmpty,
    );

    for (var k = 0; k < lines.length; k++) {
      final isLast = k == lines.length - 1;
      final offset = math.max(0, lines[k].offset - indentLength);
      builder.place(
        paragraphIndex: i,
        text: lines[k].text,
        lineHeight: lines[k].height,
        spacing: isLast ? typography.paragraphSpacing : 0,
        offset: paragraphStart + offset,
        endsParagraph: isLast,
      );
    }
  }

  return builder.finish();
}

/// 找到包含 [offset] 的页。章节内正文偏移 → 页码。
int pageIndexForOffset(List<PageSlice> pages, int offset) {
  if (pages.isEmpty) return 0;
  var low = 0;
  var high = pages.length - 1;
  var answer = 0;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (pages[mid].startOffset <= offset) {
      answer = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return answer;
}

/// 章内百分比（0~1）→ 页码。core 的进度里 scrollPercent 就是按这个口径存。
int pageIndexForPercent(List<PageSlice> pages, double percent) {
  if (pages.length <= 1) return 0;
  final clamped = percent.clamp(0.0, 1.0);
  return (clamped * pages.length).floor().clamp(0, pages.length - 1);
}

/// 页码 → 章内百分比（0~1）。
double percentForPageIndex(List<PageSlice> pages, int pageIndex) {
  if (pages.isEmpty) return 0;
  final index = pageIndex.clamp(0, pages.length - 1);
  return index / pages.length;
}

class _MeasuredLine {
  const _MeasuredLine(this.text, this.height, this.offset);

  final String text;
  final double height;

  /// 在「带缩进的 display 串」中的起始字符下标。
  final int offset;
}

List<_MeasuredLine> _measureParagraph({
  required String display,
  required TextStyle style,
  required double maxWidth,
  required TextScaler textScaler,
  required ReaderTypography typography,
  required bool isBlank,
}) {
  if (isBlank) {
    return [_MeasuredLine('', typography.blankLineHeight, 0)];
  }

  final painter = TextPainter(
    text: TextSpan(text: display, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.justify,
    textScaler: textScaler,
  )..layout(maxWidth: maxWidth);

  try {
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      return [_MeasuredLine(display, typography.blankLineHeight, 0)];
    }

    final lines = <_MeasuredLine>[];
    var cursor = 0;
    for (final metric in metrics) {
      var end = cursor;
      if (cursor < display.length) {
        final range = painter.getLineBoundary(TextPosition(offset: cursor));
        end = math.min(range.end, display.length);
        // 防御：极端字体/空白字符下可能拿到退化区间，直接吃掉剩余文本，
        // 否则会出现死循环。
        if (end <= cursor) end = display.length;
      }
      lines.add(
        _MeasuredLine(
          cursor < display.length ? display.substring(cursor, end) : '',
          metric.height,
          cursor,
        ),
      );
      cursor = end;
      if (cursor >= display.length) break;
    }

    if (cursor < display.length) {
      // 行边界与文本长度不闭合时，把剩余文本挂到最后一行，宁可多一行也不丢字。
      final last = lines.removeLast();
      lines.add(
        _MeasuredLine(
          '${last.text}${display.substring(cursor)}',
          last.height,
          last.offset,
        ),
      );
    }
    return lines;
  } finally {
    painter.dispose();
  }
}

/// 逐行装页。单独抽出来是因为「页满换页 + 同段合并」的边界条件较多，
/// 集中在一处比散落在 paginate 主循环里好维护。
class _PageBuilder {
  _PageBuilder({required this.pageHeight});

  final double pageHeight;
  final List<PageSlice> _pages = [];
  final List<PageBlock> _blocks = [];
  double _used = 0;
  int _pageStartOffset = 0;

  void place({
    required int paragraphIndex,
    required String text,
    required double lineHeight,
    required double spacing,
    required int offset,
    required bool endsParagraph,
  }) {
    // 本行放不下就换页；页内至少保留一行，避免「行高 > 版心」时死循环。
    if (_blocks.isNotEmpty && _used + lineHeight > pageHeight + 0.01) {
      _flush();
    }
    if (_blocks.isEmpty) _pageStartOffset = offset;

    // 同一段落的连续行合并成一个块：渲染时才能整体两端对齐，
    // 也避免每行一个 Text 造成的额外布局开销。
    if (_blocks.isNotEmpty && _blocks.last.paragraphIndex == paragraphIndex) {
      final last = _blocks.removeLast();
      _blocks.add(
        PageBlock(
          paragraphIndex: paragraphIndex,
          text: '${last.text}$text',
          endsParagraph: endsParagraph,
          offset: last.offset,
        ),
      );
    } else {
      _blocks.add(
        PageBlock(
          paragraphIndex: paragraphIndex,
          text: text,
          endsParagraph: endsParagraph,
          offset: offset,
        ),
      );
    }
    _used += lineHeight;

    // 段末间距放不下就丢掉：页脚空白不值得为它单开一页。
    if (endsParagraph && _used + spacing <= pageHeight + 0.01) {
      _used += spacing;
    }
  }

  void _flush() {
    _pages.add(
      PageSlice(
        index: _pages.length,
        blocks: List<PageBlock>.unmodifiable(_blocks),
        startOffset: _pageStartOffset,
      ),
    );
    _blocks.clear();
    _used = 0;
  }

  List<PageSlice> finish() {
    if (_blocks.isNotEmpty) _flush();
    if (_pages.isEmpty) {
      _pages.add(const PageSlice(index: 0, blocks: [], startOffset: 0));
    }
    return _pages;
  }
}
