/// 轻量 HTML → 纯文本段落。
///
/// 为什么不引第三方 HTML 包：core 返回的正文是书源抓下来的片段，
/// 结构千奇百怪但共性很简单——块级标签切段、行内标签丢弃、实体解码。
/// 引入完整解析器既增加包体，也会把「脏 HTML」当成错误抛出来，
/// 对阅读器反而是负担。这里只做容错式压平。
library;

class HtmlText {
  HtmlText._();

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
  /// - HTML 源码里的裸换行无意义，先剔除，避免把格式化缩进变成空段落。
  static List<String> toParagraphs(String html) {
    if (html.isEmpty) return const [];

    var s = html.replaceAll(_comment, '').replaceAll(_hiddenBlock, '');
    // 源码换行/回车在 HTML 里不产生视觉效果，先去掉，防止被当成空段落。
    s = s.replaceAll('\r', '').replaceAll('\n', '');
    s = s.replaceAll(_lineBreak, '\n');
    s = s.replaceAll(_closingBlock, '\n');
    s = s.replaceAll(_openBlock, '');
    s = s.replaceAll(_tag, '');
    s = _decodeEntities(s).replaceAll(_zeroWidth, '');

    final out = <String>[];
    for (final rawLine in s.split('\n')) {
      final line = rawLine.replaceAll(_spaces, ' ').trim();
      if (line.isEmpty) {
        if (out.isNotEmpty && out.last.isNotEmpty) out.add('');
        continue;
      }
      out.add(line);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out;
  }

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
