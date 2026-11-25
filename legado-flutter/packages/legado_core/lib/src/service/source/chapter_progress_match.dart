/// 换源 / 更新目录时的「章节定位」算法。
///
/// 逐行移植 Kotlin 原版 `BookHelp.getDurChapter` + `getChapterNum` +
/// `getPureChapterName`（`app/src/main/java/io/legado/app/help/book/BookHelp.kt`）。
///
/// 为什么不能用「按序号 clamp」：新源的章节可能少了几章前言、多了一堆番外，
/// 序号一整体偏移，用户换源后打开就是完全不相干的一章。原版的做法是
/// **先按章名相似度找**（同一个章节名一般不变），找不到再按章节号在 ±10
/// 的窗口里找最接近的，最后才回落到原序号。
library;

/// Jaccard 相似度（字符集合），与 `org.apache.commons.text.similarity.JaccardSimilarity`
/// 同算法 —— 原版用的就是它，换算法会让阈值 0.96 失去意义。
double jaccardSimilarity(String left, String right) {
  final a = left.split('').toSet();
  final b = right.split('').toSet();
  if (a.isEmpty && b.isEmpty) return 1;
  final union = {...a, ...b};
  if (union.isEmpty) return 1;
  var intersect = 0;
  for (final ch in a) {
    if (b.contains(ch)) intersect++;
  }
  return intersect / union.length;
}

const _numerals = r'0-9零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟';

final _chapterNumPattern1 =
    RegExp('.*?第([$_numerals]+)[章节篇回集话]');
final _chapterNumPattern2 =
    RegExp('^(?:[$_numerals]+[,:、])*([$_numerals]+)(?:[,:、]|\\.[^0-9])');

/// 章节序号，取不到返回 -1（原版 `getChapterNum`）。
int chapterNumOf(String? title) {
  if (title == null) return -1;
  final text = _fullToHalf(title).replaceAll(_whitespace, '');
  final m = _chapterNumPattern1.firstMatch(text) ??
      _chapterNumPattern2.firstMatch(text);
  if (m == null) return -1;
  final value = _stringToInt(m.group(1) ?? '');
  return value ?? -1;
}

final _whitespace = RegExp(r'\s');

/// 去掉「章节序号 + 括号」后的纯章名，用来比相似度（原版 `getPureChapterName`）。
///
/// 三条正则的顺序与原版一致，且都带 `(?!$)` 之类的保护：整章名就是「第1章」
/// 时不能把它清成空串，否则所有章节的纯名都是空、相似度全 0。
final _regexB = RegExp(
  '^.*?第(?:[$_numerals]+)[章节篇回集话](?!\$)|'
  '^(?:[$_numerals]+[,:、])*(?:[$_numerals]+)(?:[,:、](?!\$)|\\\\.(?=[^0-9]))',
);
final _regexC = RegExp(
  '(?!^)(?:[〖【《〔\\[{(][^〖【《〔\\[{()〕》】〗\\]}]+)?[)〕》】〗\\]}]+\$|'
  '^[〖【《〔\\[{(](?:[^〖【《〔\\[{()〕》】〗\\]}]+[〕》】〗\\]})])?(?!\$)',
);
final _regexOther = RegExp(
  '[^\\w\\u4E00-\\u9FEF〇\\u3400-\\u4DBF\\u{20000}-\\u{2A6DF}\\u{2A700}-\\u{2EBEF}]',
  unicode: true,
);

String pureChapterName(String? title) {
  if (title == null) return '';
  return _fullToHalf(title)
      .replaceAll(_whitespace, '')
      .replaceAll(_regexB, '')
      .replaceAll(_regexC, '')
      .replaceAll(_regexOther, '');
}

/// 全角 → 半角（原版 `StringUtils.fullToHalf`），只处理 ASCII 可见区与全角空格。
String _fullToHalf(String input) {
  final buffer = StringBuffer();
  for (final code in input.runes) {
    if (code == 0x3000) {
      buffer.writeCharCode(0x20);
    } else if (code >= 0xFF01 && code <= 0xFF5E) {
      buffer.writeCharCode(code - 0xFEE0);
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}

const _cnDigits = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '壹': 1,
  '二': 2,
  '两': 2,
  '贰': 2,
  '三': 3,
  '叁': 3,
  '四': 4,
  '肆': 4,
  '五': 5,
  '伍': 5,
  '六': 6,
  '陆': 6,
  '七': 7,
  '柒': 7,
  '八': 8,
  '捌': 8,
  '九': 9,
  '玖': 9,
};

const _cnUnits = {
  '十': 10,
  '拾': 10,
  '百': 100,
  '佰': 100,
  '千': 1000,
  '仟': 1000,
  '万': 10000,
};

/// 阿拉伯数字或中文数字 → int。解析不了返回 null（原版返回 -1）。
int? _stringToInt(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final pure = int.tryParse(text);
  if (pure != null) return pure;

  var total = 0;
  var current = 0;
  var matched = false;
  for (final ch in text.split('')) {
    final digit = _cnDigits[ch];
    if (digit != null) {
      current = digit;
      matched = true;
      continue;
    }
    final unit = _cnUnits[ch];
    if (unit == null) return null;
    matched = true;
    if (unit == 10000) {
      // 「一万」「三万五」这种：把当前累计整体进位。
      total = (total + current) * unit;
      current = 0;
    } else {
      // 「十二」= 1*10 + 2，此时 current 为 0 也要按 1 算。
      total += (current == 0 ? 1 : current) * unit;
      current = 0;
    }
  }
  if (!matched) return null;
  return total + current;
}

/// 旧书的阅读位置在新目录里对应的下标。
///
/// 参数与原版 `getDurChapter(oldDurChapterIndex, oldDurChapterName, newChapterList, oldChapterListSize)`
/// 一一对应：[newChapterTitles] 是新目录的章节名（按阅读顺序），
/// [oldChapterListSize] 是旧目录的总章数（用于在章节数变化时按比例缩放序号）。
int migrateChapterIndex({
  required int oldIndex,
  required String? oldTitle,
  required List<String> newChapterTitles,
  int oldChapterListSize = 0,
}) {
  if (oldIndex <= 0) return 0;
  if (newChapterTitles.isEmpty) return oldIndex;

  final oldNum = chapterNumOf(oldTitle);
  final pureOld = pureChapterName(oldTitle);
  final newSize = newChapterTitles.length;
  final scaled = oldChapterListSize == 0
      ? oldIndex
      : oldIndex * oldChapterListSize ~/ newSize;
  var min = oldIndex < scaled ? oldIndex : scaled;
  if (min > 10) min -= 10;
  min = min < 0 ? 0 : min;
  var max = oldIndex > scaled ? oldIndex : scaled;
  max = max + 10 > newSize - 1 ? newSize - 1 : max + 10;

  var nameSim = 0.0;
  var newIndex = 0;
  var newNum = 0;

  if (pureOld.isNotEmpty) {
    for (var i = min; i <= max; i++) {
      final temp = jaccardSimilarity(pureOld, pureChapterName(newChapterTitles[i]));
      if (temp > nameSim) {
        nameSim = temp;
        newIndex = i;
      }
    }
  }

  if (nameSim < 0.96 && oldNum > 0) {
    for (var i = min; i <= max; i++) {
      final temp = chapterNumOf(newChapterTitles[i]);
      if (temp == oldNum) {
        newNum = temp;
        newIndex = i;
        break;
      } else if ((temp - oldNum).abs() < (newNum - oldNum).abs()) {
        newNum = temp;
        newIndex = i;
      }
    }
  }

  if (nameSim > 0.96 || (newNum - oldNum).abs() < 1) {
    return newIndex;
  }
  final fallback = oldIndex > newSize - 1 ? newSize - 1 : oldIndex;
  return fallback < 0 ? 0 : fallback;
}
