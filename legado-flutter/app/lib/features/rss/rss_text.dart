/// RSS 展示用的轻量文本工具。
///
/// 为什么不引第三方 HTML 包：订阅正文是各站点抓来的片段，结构很脏，
/// 完整解析器会把「不合法 HTML」当错误抛出，对阅读器是负担。
/// 这里只做容错式压平：丢弃标签、实体解码、块级标签切段。
library;

import '../../core/format.dart';

class RssText {
  RssText._();

  static final RegExp _comment = RegExp(r'<!--[\s\S]*?-->');
  static final RegExp _hiddenBlock =
      RegExp(r'<(script|style|head)\b[^>]*>[\s\S]*?</\1\s*>', caseSensitive: false);
  static final RegExp _lineBreak =
      RegExp(r'<\s*(?:br|hr)\s*/?\s*>', caseSensitive: false);
  static final RegExp _closingBlock = RegExp(
    r'<\s*/\s*(?:p|div|h[1-6]|li|ul|ol|tr|table|blockquote|section|article|figure|pre)\s*>',
    caseSensitive: false,
  );
  static final RegExp _openBlock = RegExp(
    r'<\s*(?:p|div|h[1-6]|li|ul|ol|tr|table|blockquote|section|article|figure|pre)\b[^>]*>',
    caseSensitive: false,
  );
  static final RegExp _tag = RegExp(r'<[^>]*>');
  static final RegExp _numericEntity = RegExp(r'&#(x?[0-9a-fA-F]+);');
  static final RegExp _namedEntity = RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);');
  static final RegExp _inlineSpaces = RegExp(r'[ \t\u00A0\u3000]+');
  static final RegExp _manyNewlines = RegExp(r'\n{3,}');

  /// 常见命名实体。收录标准里阅读场景最常出现的几个，其余原样保留。
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
    'euro': '€',
    'copy': '©',
    'reg': '®',
    'trade': '™',
  };

  /// HTML → 纯文本。块级标签转换为段落换行，行内标签直接丢弃。
  static String stripHtml(String? raw) {
    final input = raw ?? '';
    if (input.trim().isEmpty) return '';

    var text = input.replaceAll(_comment, ' ');
    text = text.replaceAll(_hiddenBlock, ' ');
    text = text.replaceAll(_lineBreak, '\n');
    // 结束块标签是「这段到此结束」；开始块标签只需丢弃，
    // 这样 `<p>A</p><p>B</p>` 得到两段，而不会多出空行。
    text = text.replaceAll(_closingBlock, '\n\n');
    text = text.replaceAll(_openBlock, '');
    text = text.replaceAll(_tag, '');
    text = decodeEntities(text);

    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    // 逐行收拢空白，保留段落之间的空行。
    final lines = text
        .split('\n')
        .map((line) => line.replaceAll(_inlineSpaces, ' ').trim())
        .toList();
    text = lines.join('\n').replaceAll(RegExp(r' *\n *'), '\n');
    text = text.replaceAll(_manyNewlines, '\n\n');
    return text.trim();
  }

  /// 实体解码：数字实体（含十六进制）与常见命名实体。
  static String decodeEntities(String input) {
    var out = input.replaceAllMapped(_numericEntity, (m) {
      final body = m[1] ?? '';
      final hex = body.startsWith('x') || body.startsWith('X');
      final code = hex
          ? int.tryParse(body.substring(1), radix: 16)
          : int.tryParse(body);
      if (code == null || code <= 0 || code > 0x10FFFF) return m[0] ?? '';
      return String.fromCharCode(code);
    });
    out = out.replaceAllMapped(_namedEntity, (m) {
      final name = (m[1] ?? '').toLowerCase();
      return _entities[name] ?? m[0] ?? '';
    });
    return out;
  }

  /// 列表里的摘要：压成一行并截断。
  static String snippet(String? raw, {int maxLength = 96}) {
    final text = stripHtml(raw).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length <= maxLength) return text;
    return '${text.substring(0, maxLength)}…';
  }

  /// 源站时间（Unix 秒）→ 列表里的相对时间。
  static String formatTime(int unixSeconds) {
    if (unixSeconds <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.isNegative) return '刚刚';
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';

    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(time.year, time.month, time.day);
    final days = today.difference(day).inDays;
    if (days == 1) return '昨天';
    if (days > 1 && days < 7) return '$days 天前';
    if (time.year == now.year) return '${time.month} 月 ${time.day} 日';
    return '${time.year}-${_two(time.month)}-${_two(time.day)}';
  }

  /// 正文页头部的完整时间。
  static String formatDateTime(int unixSeconds) {
    if (unixSeconds <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }

  /// 取 URL 的 host 用于副标题；解析失败时退回原串。
  static String hostOf(String? url) {
    final text = (url ?? '').trim();
    if (text.isEmpty) return '';
    final uri = Uri.tryParse(text);
    final host = uri?.host ?? '';
    if (host.isNotEmpty) return host;
    return text
        .replaceFirst(RegExp(r'^[a-zA-Z]+://'), '')
        .split('/')
        .first;
  }

  /// 订阅地址的基础校验：只接受 http/https。
  static String? validateFeedUrl(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return '订阅地址不能为空';
    final uri = Uri.tryParse(text);
    if (uri == null) return '地址格式不正确';
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '需要以 http:// 或 https:// 开头';
    }
    if (uri.host.isEmpty) return '地址缺少域名';
    return null;
  }

  static String _two(int value) => twoDigits(value);
}
