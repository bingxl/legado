import 'dart:typed_data';

import 'parsed_book.dart';
import 'text_codec.dart';
import 'txt_toc_rules.dart';

/// 纯文本（TXT）解析器。
///
/// 分章算法对齐原版 `TextFile.getChapterList`：**全文扫描 + 位置排序**，
/// 相邻两个标题之间即上一章正文。不做逐行切分——那样一行内能出现两个标题时
/// 就漏章（"第一章 起\n　　他翻到第三章" 这种排版真实存在）。
///
/// 与 Kotlin 版的两处有意偏差（都是为了"少丢章"）：
/// 1. 章节偏移按**字节**记录（`start`/`end`），与原版 `BookChapter` 一致；
///    Kotlin 里额外有"按 100KB 强行拆长章"的逻辑，这里没做——它会让
///    同一章的内容被切成 `第一章(1)` `第一章(2)`，多数读者并不想要。
/// 2. 相邻标题的最小间距按全文长度缩放（上限 500 字符），而不是硬编码 1000。
///    原版阈值对短篇集（一章几百字）过狠，会直接丢掉一半章节。
///
/// 实例是**有状态**的：`parse` 之后 `contentOf` 才能按偏移取正文。
/// 这不是设计上的洁癖失败——正文动辄几 MB，每个 `ParsedChapter`
/// 都揣一份字符串会让内存翻倍，而调用方通常只读当前一章。
class TxtParser {
  TxtParser({this.charset, List<Object>? tocRules})
    : tocRules = tocRules
          ?.map<TxtTocRule>(
            (e) => e is TxtTocRule ? e : TxtTocRule.parse(e as String),
          )
          .toList(growable: false);

  /// 调用方指定的编码（为空则自己探测）。
  final String? charset;

  /// 自定义目录规则；为空时用 [defaultTxtTocRules]。
  final List<TxtTocRule>? tocRules;

  /// 标题行的最大长度。超过它的一律当正文（目录页噪声的典型特征）。
  static const maxTitleLength = 40;

  Uint8List? _bytes;
  String _charset = CharsetName.utf8;

  /// 本次解析实际使用的编码（探测结果也算）。UI 的"重新分章/改编码"要用它回填。
  String get usedCharset => _charset;

  /// 解析一本 TXT。
  ///
  /// [fileName] 只用来推断书名（去掉扩展名），不影响分章。
  ParsedBook parse(Uint8List bytes, {String? fileName}) {
    if (bytes.isEmpty) {
      throw BookParseException('文件为空');
    }
    final cs = normalizeCharset(charset ?? detectCharset(bytes));
    final text = decodeText(bytes, cs);
    if (text.trim().isEmpty) {
      throw BookParseException('文件内容为空');
    }

    _bytes = bytes;
    _charset = cs;

    final bom = bomLengthOf(bytes, cs);
    final mapper = ByteOffsetMapper(text, cs, baseOffset: bom);
    final marks = _dropEchoMarks(
      _locate(text, tocRules ?? defaultTxtTocRules),
      text,
    );

    final chapters = <ParsedChapter>[];
    if (marks.isNotEmpty && marks.first.start > 0) {
      final lead = text.substring(0, marks.first.start);
      if (lead.trim().isNotEmpty &&
          !_looksLikeTocPage(lead, marks.map((m) => m.title).toSet())) {
        // 第一个标题之前的内容：书名页、作者、简介……原版叫"前言"。
        chapters.add(
          _chapter(
            title: '前言',
            index: 0,
            startByte: bom,
            endByte: mapper.byteAt(marks.first.start),
            bytes: bytes,
            charset: cs,
          ),
        );
      }
    }

    for (var i = 0; i < marks.length; i++) {
      final mark = marks[i];
      final endChar = i + 1 < marks.length ? marks[i + 1].start : text.length;
      if (endChar <= mark.start) continue;
      final startByte = mapper.byteAt(mark.start);
      final endByte = mapper.byteAt(endChar);
      chapters.add(
        _chapter(
          title: mark.title,
          index: chapters.length,
          startByte: startByte,
          endByte: endByte,
          bytes: bytes,
          charset: cs,
        ),
      );
    }

    if (chapters.isEmpty) {
      // 一个标题都没认出来：整本当一章。原文要求如此，
      // 也不做"按 5000 字强切"——那会把书变成几百个"第 N 节"，读者找不回原状。
      chapters.add(
        _chapter(
          title: '正文',
          index: 0,
          startByte: bom,
          endByte: bytes.length,
          bytes: bytes,
          charset: cs,
        ),
      );
    } else {
      // 末尾常见"最新章节""求收藏"之类的尾巴，单独成章没有意义。
      while (chapters.length > 1 && _isBlankBody(chapters.last)) {
        chapters.removeLast();
      }
    }

    for (var i = 0; i < chapters.length; i++) {
      chapters[i] = _reindex(chapters[i], i);
    }

    return ParsedBook(
      title: _titleOf(fileName, text, marks),
      format: BookFormat.txt,
      chapters: chapters,
      metadata: {'charset': cs, 'fileName': ?fileName},
    );
  }

  /// 构造一章。正文走 [ParsedChapter.contentLoader] 延迟解码。
  ParsedChapter _chapter({
    required String title,
    required int index,
    required int startByte,
    required int endByte,
    required Uint8List bytes,
    required String charset,
  }) {
    return ParsedChapter(
      title: title,
      index: index,
      start: startByte,
      end: endByte,
      contentLoader: () => _cleanBody(
        decodeRange(bytes, startByte, endByte, charset),
        title,
      ),
    );
  }

  ParsedChapter _reindex(ParsedChapter c, int index) => ParsedChapter(
    title: c.title,
    index: index,
    start: c.start,
    end: c.end,
    content: c.content,
    contentLoader: c.contentLoader,
  );

  /// 去掉"目录页回声"。
  ///
  /// 盗版 txt 常见结构：开头一整页 `第一章 xxx` 的目录，然后才是正文。
  /// 这些目录行本身也是合法标题行，单靠间距滤不干净（第一条总能活下来）。
  /// 判据：**同一个标题在后面又出现一次，而前面那次几乎没有正文**。
  /// 100 字符的窗口足够容纳"标题行 + 页码"，又不至于误伤真的同名短章。
  List<_Mark> _dropEchoMarks(List<_Mark> marks, String text) {
    if (marks.length < 2) return marks;
    final seen = <String>{};
    final drop = <int>{};
    for (var i = marks.length - 1; i >= 0; i--) {
      final mark = marks[i];
      if (seen.add(mark.title)) continue;
      final next = i + 1 < marks.length ? marks[i + 1].start : text.length;
      if (next - mark.start < 100) drop.add(i);
    }
    if (drop.isEmpty) return marks;
    final kept = <_Mark>[];
    for (var i = 0; i < marks.length; i++) {
      if (!drop.contains(i)) kept.add(marks[i]);
    }
    return kept;
  }

  /// 这段"前言"是不是其实一页目录。
  ///
  /// 判据：所有非空行要么是"目录"，要么就是某个章节标题。
  /// 是的话它只是目录页，不该单独成为一章（读者点进去只会看到一串标题）。
  bool _looksLikeTocPage(String lead, Set<String> titles) {
    var lines = 0;
    for (final raw in lead.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      lines++;
      if (line == '目录' || line == '目 录' || titles.contains(line)) continue;
      return false;
    }
    return lines > 0;
  }

  /// 取某一章的正文（延迟解码，只读这一章）。
  ///
  /// 返回的正文**不含标题行**：标题由 UI 单独渲染，正文里再出现一遍
  /// 就是"每章开头重复一次章节名"的经典丑 bug。
  String contentOf(ParsedChapter chapter) {
    final bytes = _bytes;
    if (bytes == null) {
      throw StateError('请先调用 parse 再取正文');
    }
    final start = chapter.start;
    final end = chapter.end;
    if (start == null || end == null) {
      throw ArgumentError('章节缺少偏移信息: $chapter');
    }
    final raw = decodeRange(bytes, start, end, _charset);
    return _cleanBody(raw, chapter.title);
  }

  // ---------------------------------------------------------------- 分章

  List<_Mark> _locate(String text, List<TxtTocRule> rules) {
    final gap = _chapterGap(text.length);
    var best = const <_Mark>[];
    for (final rule in rules) {
      RegExp re;
      try {
        re = rule.compile();
      } on FormatException {
        // 用户规则写错不该让整本书打不开，跳过继续试下一条。
        continue;
      }
      final marks = _scan(text, re, rule, gap);
      // 命中最多者胜出；相同则保留靠前的规则（更"精确"的那条）。
      if (marks.length > best.length) best = marks;
    }
    return best;
  }

  /// 相邻标题之间至少要隔多少字符，才认为后一个是真标题。
  ///
  /// 目的是滤掉目录页：目录页里几十个标题挤在一起，间距远小于正文。
  /// 原版硬编码 1000（面向一章两三千字的网文）；短篇集里一章可能只有几百字，
  /// 硬阈值会滤掉真章节，所以这里按全文长度缩放。
  int _chapterGap(int textLength) {
    final scaled = textLength ~/ 100;
    if (scaled > 500) return 500;
    return scaled < 8 ? 8 : scaled;
  }

  List<_Mark> _scan(String text, RegExp re, TxtTocRule rule, int gap) {
    final marks = <_Mark>[];
    var lastEnd = 0;
    for (final m in re.allMatches(text)) {
      final lineStart = _lineStart(text, m.start);
      final lineEnd = _lineEnd(text, m.end > lineStart ? m.end : lineStart);
      // 标题行必须是"整行"的：匹配点前面只能是空白。
      // 否则「他翻到第三章」这种句子里的 第三章 也会变成章节。
      if (!_isBlank(text, lineStart, m.start)) continue;
      final title = _titleFromMatch(text, lineStart, lineEnd, m, rule);
      if (!_isPlausibleTitle(title)) continue;
      if (marks.isNotEmpty && lineStart - lastEnd <= gap) continue;
      marks.add(_Mark(lineStart, lineEnd, title));
      lastEnd = lineEnd;
    }
    return marks;
  }

  String _titleFromMatch(
    String text,
    int lineStart,
    int lineEnd,
    RegExpMatch match,
    TxtTocRule rule,
  ) {
    final template = rule.titleTemplate;
    if (template == null) {
      return text.substring(lineStart, lineEnd).trim();
    }
    var out = template;
    // 倒序替换：否则 `$1` 会先把 `$12` 拆坏。
    for (var g = match.groupCount; g >= 0; g--) {
      final value = match.group(g) ?? '';
      out = out.replaceAll('\$$g', value);
    }
    return out.trim();
  }

  bool _isPlausibleTitle(String title) {
    if (title.isEmpty) return false;
    if (title.length > maxTitleLength) return false;
    if (title.contains('目录')) return false;
    if (title.contains('最新章节')) return false;
    // 目录页的尾巴：章节名后跟一串点和一个页码。
    if (RegExp(r'[.·…‥]{3,}\s*\d{1,4}$').hasMatch(title)) return false;
    if (RegExp(r'(求票|求推荐|推荐票|手机版|最新章节|全文阅读|加入书签)').hasMatch(title)) {
      return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- 工具

  /// 标题为空时，用正文第一行当书名；再不行用文件名。
  String _titleOf(String? fileName, String text, List<_Mark> marks) {
    if (fileName != null && fileName.trim().isNotEmpty) {
      final base = fileName.split(RegExp(r'[\\/]')).last;
      final dot = base.lastIndexOf('.');
      final name = dot > 0 ? base.substring(0, dot) : base;
      if (name.trim().isNotEmpty) return name.trim();
    }
    final head = marks.isNotEmpty && marks.first.start > 0
        ? text.substring(0, marks.first.start)
        : text;
    for (final line in head.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) return t.length <= 80 ? t : t.substring(0, 80);
    }
    return '未命名';
  }

  /// 去掉标题行、首尾空白，并把段首缩进统一成两个全角空格。
  String _cleanBody(String raw, String title) =>
      cleanTxtChapterBody(raw, title);

  static bool _sameTitle(String line, String title) {
    if (line == title) return true;
    // 标题行常带尾部装饰（★、"（求票）"），只比前缀。
    return line.length >= 2 && title.length >= 2 && line.startsWith(title);
  }

  /// 去掉分章区间首行的「目录回声」（章节标题被算进正文）。
  ///
  /// 供 Reader 域按字节偏移取正文时复用：导入时和阅读时必须用同一套清洗规则，
  /// 否则书架预览与阅读器正文会差一行。
  static String cleanTxtChapterBody(String raw, String title) {
  var body = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final firstBreak = body.indexOf('\n');
  final firstLine = (firstBreak < 0 ? body : body.substring(0, firstBreak)).trim();
  if (firstLine.isNotEmpty && TxtParser._sameTitle(firstLine, title)) {
    body = firstBreak < 0 ? '' : body.substring(firstBreak + 1);
  }
  body = body.trim();
  if (body.isEmpty) return '';
  // 段首有缩进的保留，没有的不强加：强行替换会把对齐的诗歌/表格毁掉。
  return body;
}

  bool _isBlankBody(ParsedChapter chapter) {
    final content = chapter.readContent();
    return (content ?? '').trim().isEmpty;
  }

  static int _lineStart(String text, int index) {
    if (index <= 0) return 0;
    final i = text.lastIndexOf('\n', index - 1);
    return i < 0 ? 0 : i + 1;
  }

  static int _lineEnd(String text, int index) {
    if (index >= text.length) return text.length;
    final i = text.indexOf('\n', index);
    return i < 0 ? text.length : i;
  }

  static bool _isBlank(String text, int start, int end) {
    for (var i = start; i < end; i++) {
      final c = text.codeUnitAt(i);
      if (c != 0x20 && c != 0x09 && c != 0x3000 && c != 0xA0) return false;
    }
    return true;
  }
}

/// 一个目录命中点（字符下标，转字节偏移在装配章节时做）。
class _Mark {
  const _Mark(this.start, this.end, this.title);

  final int start;
  final int end;
  final String title;

  @override
  String toString() => '_Mark($start-$end, $title)';
}
