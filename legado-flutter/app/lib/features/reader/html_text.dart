/// 轻量 HTML → 纯文本段落。
///
/// 为什么不引第三方 HTML 包：core 返回的正文是书源抓下来的片段，
/// 结构千奇百怪但共性很简单——块级标签切段、行内标签丢弃、实体解码。
/// 引入完整解析器既增加包体，也会把「脏 HTML」当成错误抛出来，
/// 对阅读器反而是负担。这里只做容错式压平。
library;

/// 一章正文的解析结果。
///
/// [paragraphs] 与 [imageUrls] 用同一个下标：某段是图片时段落串为空串，
/// 地址放在 [imageUrls] 里。这样图片在正文里有确定的位置，分页时按独立块
/// 占位，渲染时才能「图在文中」而不是被当成漫画整章铺开。
class ChapterContent {
  const ChapterContent({
    required this.paragraphs,
    required this.imageUrls,
  });

  final List<String> paragraphs;
  final Map<int, String> imageUrls;

  bool get hasText => paragraphs.any((p) => p.trim().isNotEmpty);
  bool get isEmpty => paragraphs.isEmpty && imageUrls.isEmpty;
}

class HtmlText {
  HtmlText._();

  /// 正文图片在段落串里的占位符（U+FFFC OBJECT REPLACEMENT CHARACTER）。
  static const String imageMarker = '\uFFFC';

  static final RegExp _imgTag = RegExp(r'<img\b[^>]*>', caseSensitive: false);
  static final RegExp _imgAttr = RegExp(
    r'''(?:src|data-src|specialdata-src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );
  static final RegExp _imageLine = RegExp('^$imageMarker(\\d+)\$');
  static final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _hiddenBlock = RegExp(
    r'<(script|style|head)\b[^>]*>[\s\S]*?</\1\s*>',
    caseSensitive: false,
  );
  // <br> 是段内换行，<hr> 是场景分隔线，两者对纯文本来说都等于断行。
  static final RegExp _lineBreak = RegExp(
    r'<\s*(?:br|hr)\s*/?\s*>',
    caseSensitive: false,
  );
  // 结束块标签表示「这一段结束了」，替换成换行；开始块标签只需丢弃。
  // 这样 `<p>A</p><p>B</p>` 恰好得到 A、B 两段，而不是中间多出空行。
  static final RegExp _closingBlock = RegExp(
    r'<\s*/\s*(?:p|div|h[1-6]|li|ul|ol|tr|table|blockquote|section|article)\s*>',
    caseSensitive: false,
  );
  static final RegExp _openBlock = RegExp(
    r'<\s*(?:p|div|h[1-6]|li|ul|ol|tr|table|blockquote|section|article)\b[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _tag = RegExp(r'<[^>]*>');
  static final RegExp _numericEntity = RegExp(r'&#(x?[0-9a-fA-F]+);');
  static final RegExp _namedEntity = RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);');
  static final RegExp _spaces = RegExp(r'[ \t\u00A0\u3000]+');
  static final RegExp _zeroWidth = RegExp('[\u200B\u200C\u200D\uFEFF]');

  static const Map<String, String> _entities = {
    'nbsp': ' ',
    'amp': '&',
    'lt': '<',
    'gt': '>',
    'quot': '"',
    'apos': "'",
    'ldquo': '“',
    'rdquo': '”',
    'lsquo': '‘',
    'rsquo': '’',
    'hellip': '…',
    'mdash': '—',
    'ndash': '–',
    'middot': '·',
    'times': '×',
    'ensp': ' ',
    'emsp': ' ',
    'thinsp': ' ',
  };

  /// 把正文 HTML 压平成段落列表（不含首行缩进，缩进由分页阶段统一加）。
  ///
  /// 规则：
  /// - `<br>` 视为段内换行；
  /// - 结束块标签切段，开始块标签只丢弃；
  /// - 连续空行压成一段空行（保留场景分隔），段首段尾空行丢弃；
  /// - HTML 源码里的裸换行无意义，先剔除，避免把格式化缩进变成空段落；
  /// - `<img>` 独立成段，地址放进 [ChapterContent.imageUrls]。
  static ChapterContent toContent(String html) {
    if (html.isEmpty) return const ChapterContent(paragraphs: [], imageUrls: {});

    final imageUrls = <String>[];
    var s = html.replaceAll(_comment, '').replaceAll(_hiddenBlock, '');
    // 源码换行/回车在 HTML 里不产生视觉效果，先去掉，防止被当成空段落。
    s = s.replaceAll('\r', '').replaceAll('\n', '');
    // 先把图片换成「所在段落的标记」，后续和其它标签一起压平，位置不会丢。
    s = s.replaceAllMapped(_imgTag, (match) {
      final tag = match.group(0) ?? '';
      String? raw;
      for (final attr in _imgAttr.allMatches(tag)) {
        final value = attr.group(1) ?? attr.group(2) ?? attr.group(3) ?? '';
        if (value.trim().isNotEmpty) {
          raw = value.trim();
          break;
        }
      }
      if (raw == null) return '';
      final url = _decodeEntities(raw);
      if (url.isEmpty) return '';
      final index = imageUrls.length;
      imageUrls.add(url);
      return '\n$imageMarker$index\n';
    });
    s = s.replaceAll(_lineBreak, '\n');
    s = s.replaceAll(_closingBlock, '\n');
    s = s.replaceAll(_openBlock, '');
    s = s.replaceAll(_tag, '');
    s = _decodeEntities(s).replaceAll(_zeroWidth, '');

    final out = <String>[];
    final positioned = <int, String>{};
    for (final rawLine in s.split('\n')) {
      final line = rawLine.replaceAll(_spaces, ' ').trim();
      final imageMatch = _imageLine.firstMatch(line);
      if (imageMatch != null) {
        final index = int.tryParse(imageMatch.group(1) ?? '');
        if (index != null && index < imageUrls.length) {
          // 图片段本身是空串；若紧邻块标签已经产生了一个空段，直接占用它，
          // 不要留下两个连续空行把版面撑开。
          if (out.isNotEmpty && out.last.isEmpty) {
            positioned[out.length - 1] = imageUrls[index];
          } else {
            positioned[out.length] = imageUrls[index];
            out.add('');
          }
        }
        continue;
      }
      if (line.isEmpty) {
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      out.add(line);
    }
    while (out.isNotEmpty &&
        out.last.isEmpty &&
        !positioned.containsKey(out.length - 1)) {
      out.removeLast();
    }
    return ChapterContent(
      paragraphs: List<String>.unmodifiable(out),
      imageUrls: Map<int, String>.unmodifiable(positioned),
    );
  }

  /// 纯文本段落视图（图片位置为空串）。供只关心文字的调用方与旧测试使用。
  static List<String> toParagraphs(String html) => toContent(html).paragraphs;

  static String _decodeEntities(String s) {
    var result = s.replaceAllMapped(_numericEntity, (m) {
      final body = m[1]!;
      final hex = body.startsWith('x') || body.startsWith('X');
      final code = hex
          ? int.tryParse(body.substring(1), radix: 16)
          : int.tryParse(body);
      if (code == null || code <= 0 || code > 0x10FFFF) return m[0]!;
      return String.fromCharCode(code);
    });
    result = result.replaceAllMapped(
      _namedEntity,
      (m) => _entities[m[1]!.toLowerCase()] ?? m[0]!,
    );
    return result;
  }
}
