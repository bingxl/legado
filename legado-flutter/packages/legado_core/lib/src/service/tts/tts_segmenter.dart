/// 朗读分段：把正文切成「一段一口气」的片段。
///
/// 分段规则属于业务而不是 UI：它决定朗读断点、跨页续读的定位以及高亮范围。
/// 放在内核里的直接好处是 CLI 也能验证（`legado call Tts.Segment`），
/// 且 UI 换实现时断点不会悄悄变。
///
/// 算法与已删除的 Go 内核（`core/modules/tts/segment.go`）逐行对齐：
/// 两版的断点、偏移、合并阈值必须一致，否则「续读位置」在两边对不上。
library;

/// 一个朗读片段。
class TtsSegment {
  const TtsSegment({
    required this.index,
    required this.paragraph,
    required this.text,
    required this.start,
    required this.end,
  });

  /// 本章内的全局片段序号，从 0 开始、连续且不重复。
  final int index;

  /// 段落序号，从 0 开始。**空行也占一个下标**（与原文行号一一对应），
  /// 否则 UI 想把片段映射回正文第几段时会整体错位。
  final int paragraph;

  /// 要朗读的文本（已去首尾空白）。
  final String text;

  /// 片段在**所属段落内**的字符（rune）偏移，左闭右开。
  ///
  /// 特意不用 UTF-8 字节偏移：UI 侧 `substring` / 高亮按 UTF-16 码元计数，
  /// 按字节返回会让高亮范围跑到 3 倍位置。BMP 内的中文 rune 数 == UTF-16 长度，
  /// 只有行星面 emoji 会差一位，可接受（且比字节偏移错得少得多）。
  final int start;
  final int end;

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'paragraph': paragraph,
    'text': text,
    'start': start,
    'end': end,
  };

  @override
  String toString() => 'TtsSegment($index, p$paragraph, [$start,$end), "$text")';
}

/// 单个片段的默认上限。
///
/// 经验值：TTS 引擎对 100~150 字最稳；过短会让停顿碎，过长会让
/// 暂停/快进的粒度粗到「只能整段跳」。
const int defaultTtsMaxRunes = 120;

/// 中英文句末标点。
const String _sentenceEnders = '。！？；!?;…';

/// CJK 闭合引号/括号：即使不跟在句末标点后，也视作断点。
///
/// 否则「他说：『好。』」会把结尾的引号读到下一段，朗读时听感是
/// 「好。 然后走了」变成「好 然后走了’」。
const String _closingMarks = '」』”’）)》】〉"\'';

/// 二次切分的候选断点，只影响切点位置，不影响是否切。
const String _softBreaks = '，、：；,;: \u3000\t';

final Set<int> _enderSet = _sentenceEnders.runes.toSet();
final Set<int> _closingSet = _closingMarks.runes.toSet();
final Set<int> _softSet = _softBreaks.runes.toSet();

/// 把正文切成可朗读片段。
///
/// 规则：
///  1. 先按换行切段（保留段落边界，不跨段合并）；
///  2. 段内按句末标点切句，标点与紧随的闭合引号归属前一句；
///  3. 过短的句子向后合并，直到接近 [maxRunes]，避免「嗯。」单独成段；
///  4. 单句仍超长时按逗号/空格二次切分，找不到软断点才硬切。
///
/// [maxRunes] `<= 0` 时用 [defaultTtsMaxRunes]。
List<TtsSegment> splitTtsSegments(String text, int maxRunes) {
  final limit = maxRunes <= 0 ? defaultTtsMaxRunes : maxRunes;
  final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

  final out = <TtsSegment>[];
  var index = 0;

  for (var paragraph = 0; paragraph < lines.length; paragraph++) {
    final raw = lines[paragraph];
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;

    // 段首空白要计入偏移：` 他说` 里的「他」是第 1 个字符，不是第 0 个。
    final lead = raw.indexOf(trimmed);
    final base = _runeLength(raw.substring(0, lead < 0 ? 0 : lead));

    // 超长单句先切开，拼起来仍等于原句，偏移不受影响。
    final pieces = <String>[
      for (final sentence in _splitSentences(trimmed))
        ..._splitLong(sentence, limit),
    ];

    final buf = StringBuffer();
    var bufRunes = 0;
    var bufStart = 0;
    var cursor = 0;

    void flush(int end) {
      final content = buf.toString().trim();
      if (content.isNotEmpty) {
        out.add(
          TtsSegment(
            index: index++,
            paragraph: paragraph,
            text: content,
            start: base + bufStart,
            end: base + end,
          ),
        );
      }
      buf.clear();
      bufRunes = 0;
    }

    for (final piece in pieces) {
      final pieceStart = cursor;
      final pieceRunes = _runeLength(piece);
      cursor += pieceRunes;
      if (buf.isEmpty) bufStart = pieceStart;

      // 合并到接近上限；再加就超了就先吐出上一批。
      if (bufRunes + pieceRunes > limit && buf.isNotEmpty) {
        flush(pieceStart);
        bufStart = pieceStart;
      }
      buf.write(piece);
      bufRunes += pieceRunes;

      // 已经够长就直接成段，省掉后续合并判断。
      if (buf.toString().trim().runes.length >= limit) {
        flush(cursor);
      }
    }
    if (buf.isNotEmpty) flush(cursor);
  }
  return out;
}

/// 按句末标点切句，标点与紧随的闭合引号归属前一句。
List<String> _splitSentences(String s) {
  final runes = s.runes.toList();
  final out = <String>[];
  var start = 0;

  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (_enderSet.contains(r)) {
      var j = i + 1;
      // 吸收连续的句末标点与闭合引号（如 」。 或 ？！）
      while (j < runes.length &&
          (_enderSet.contains(runes[j]) || _closingSet.contains(runes[j]))) {
        j++;
      }
      out.add(_sliceRunes(runes, start, j));
      start = j;
      i = j - 1;
      continue;
    }
    // 单独的闭合引号后面若是空白，也视作断点。
    if (_closingSet.contains(r)) {
      final next = i + 1;
      if (next >= runes.length || _isSpace(runes[next])) {
        out.add(_sliceRunes(runes, start, next));
        start = next;
      }
    }
  }
  if (start < runes.length) out.add(_sliceRunes(runes, start, runes.length));
  return out;
}

/// 把超过 [limit] 的句子按软断点切成多段。
///
/// 切点尽量靠近上限，但优先落在软断点上：在词中间断开会让引擎把
/// 「的」「了」读成独立片段，听感很碎。找不到软断点才硬切。
List<String> _splitLong(String s, int limit) {
  var rest = s.runes.toList();
  if (limit <= 0 || rest.length <= limit) return <String>[s];

  final out = <String>[];
  while (rest.isNotEmpty) {
    if (rest.length <= limit) {
      out.add(String.fromCharCodes(rest));
      break;
    }
    var cut = 0;
    // 从上限往回找最近的软断点；至少切 1 个字，避免零长度死循环。
    for (var i = limit; i > 0; i--) {
      if (_softSet.contains(rest[i - 1])) {
        cut = i;
        break;
      }
    }
    if (cut <= 0) cut = limit;
    out.add(String.fromCharCodes(rest.sublist(0, cut)));
    rest = rest.sublist(cut);
  }
  return out;
}

String _sliceRunes(List<int> runes, int start, int end) =>
    String.fromCharCodes(runes.sublist(start, end));

int _runeLength(String s) => s.runes.length;

/// Go `unicode.IsSpace` 的等价实现。
///
/// `String.trim()` 的判定面与它不完全一致，这里只用于「闭合引号后面
/// 是不是空白」这一个判断，按 Go 的定义写更贴近原算法。
bool _isSpace(int r) =>
    (r >= 0x09 && r <= 0x0D) ||
    r == 0x20 ||
    r == 0x85 ||
    r == 0xA0 ||
    r == 0x1680 ||
    (r >= 0x2000 && r <= 0x200A) ||
    r == 0x2028 ||
    r == 0x2029 ||
    r == 0x202F ||
    r == 0x205F ||
    r == 0x3000;
