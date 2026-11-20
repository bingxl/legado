/// 正则规则：对齐 `AnalyzeByRegex.kt`。
///
/// 两种用途：
/// 1. 多级正则（`&&` 分隔）：前面几级用于缩小范围，最后一级提取分组；
/// 2. `##regex##replacement` 替换（在 rule 层解析，这里只提供执行）。
library;

/// 把 Java 风格正则尽量转成 Dart 能编译的形式，并返回 (pattern, ignoreCase)。
///
/// Java 允许 `\A` `\Z` `\z`，Dart（ECMAScript）不支持内联标志 `(?i)`，
/// 书源里这两类写法都有，不转换会直接抛异常导致整条规则失效。
({String pattern, bool ignoreCase}) compileRegexParts(String raw) {
  var p = raw;
  var ignoreCase = false;
  while (p.startsWith('(?i)')) {
    ignoreCase = true;
    p = p.substring(4);
  }
  p = p
      .replaceAll(r'\A', '^')
      .replaceAll(r'\Z', r'$')
      .replaceAll(r'\z', r'$');
  return (pattern: p, ignoreCase: ignoreCase);
}

RegExp? tryCompile(String raw) {
  final parts = compileRegexParts(raw);
  try {
    return RegExp(parts.pattern, caseSensitive: !parts.ignoreCase);
  } catch (_) {
    try {
      return RegExp(raw);
    } catch (_) {
      return null;
    }
  }
}

/// 匹配第一个结果并返回全部分组（`group 0` 起）。
///
/// 非最后一级时，把所有匹配拼接后再进入下一级（与 Kotlin 一致：
/// 上一级只用来把范围「缩窄」）。
List<String>? regexGetElement(String res, List<String> regs, [int index = 0]) {
  if (index >= regs.length || res.isEmpty) return null;
  final re = tryCompile(regs[index]);
  if (re == null) return null;
  final match = re.firstMatch(res);
  if (match == null) return null;
  if (index + 1 == regs.length) {
    return [
      for (var g = 0; g <= match.groupCount; g++) match.group(g) ?? '',
    ];
  }
  final sb = StringBuffer();
  for (final m in re.allMatches(res)) {
    sb.write(m.group(0));
  }
  return regexGetElement(sb.toString(), regs, index + 1);
}

/// 匹配所有结果，每个结果一组分组。
List<List<String>> regexGetElements(String res, List<String> regs,
    [int index = 0]) {
  final out = <List<String>>[];
  if (index >= regs.length || res.isEmpty) return out;
  final re = tryCompile(regs[index]);
  if (re == null) return out;
  final matches = re.allMatches(res).toList();
  if (matches.isEmpty) return out;
  if (index + 1 == regs.length) {
    for (final m in matches) {
      out.add([
        for (var g = 0; g <= m.groupCount; g++) m.group(g) ?? '',
      ]);
    }
    return out;
  }
  final sb = StringBuffer();
  for (final m in matches) {
    sb.write(m.group(0));
  }
  return regexGetElements(sb.toString(), regs, index + 1);
}

/// 执行一次正则替换，支持 `$1` / `${1}` 分组引用。
///
/// [replaceFirst] 为 true 时只处理第一个匹配（Kotlin `##regex##repl###`）。
String regexReplace(
  String input,
  String pattern,
  String replacement, {
  bool replaceFirst = false,
}) {
  final re = tryCompile(pattern);
  if (re == null) {
    // 编译失败退化为字面量替换（Kotlin 同样有这条回退）
    return replaceFirst
        ? input.replaceFirst(pattern, replacement, 0)
        : input.replaceAll(pattern, replacement);
  }
  String expand(Match m) => replacement.replaceAllMapped(
        RegExp(r'\$(\d{1,2})|\$\{(\d{1,2})\}'),
        (mm) {
          final idx = int.tryParse(mm.group(1) ?? mm.group(2) ?? '');
          if (idx == null || idx > m.groupCount) return '';
          return m.group(idx) ?? '';
        },
      );
  if (replaceFirst) {
    final m = re.firstMatch(input);
    if (m == null) return '';
    return expand(m);
  }
  return input.replaceAllMapped(re, expand);
}
