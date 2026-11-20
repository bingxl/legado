/// 规则切分：对齐原版 `RuleAnalyzer.kt` / Go 版 `splitter.go`。
///
/// 为什么不用正则切 `&&` / `||` / `@`：
/// 这些符号在 JSONPath 过滤器（`[?(@.a>1&&@.b<2)]`）、CSS 属性选择器
/// （`a[href*=x@y]`）和 JS 片段里都会出现，正则无法区分「结构符」与「内容」。
/// 原版的做法是按 `[]`/`()` 嵌套深度 + 引号状态做状态机切分，这里照做。
library;

/// 一次组合切分的结果：[type] 为命中的分隔符（未命中为空串），[parts] 为各段。
class SplitResult {
  const SplitResult(this.type, this.parts);
  final String type;
  final List<String> parts;
}

/// 按组合符切分，**只按最先出现的那个分隔符**切分（与 Kotlin/Go 一致）。
SplitResult splitCombinator(String data, List<String> seps) {
  if (data.isEmpty || seps.isEmpty) {
    return SplitResult('', <String>[data]);
  }
  var firstPos = -1;
  var firstTok = '';
  for (final s in seps) {
    final p = _findTopLevel(data, s);
    if (p >= 0 && (firstPos < 0 || p < firstPos)) {
      firstPos = p;
      firstTok = s;
    }
  }
  if (firstPos < 0 || firstTok.isEmpty) {
    return SplitResult('', <String>[data]);
  }
  return SplitResult(firstTok, splitTopLevel(data, firstTok));
}

/// 按分隔符在「顶层」（括号/引号之外）切分。
List<String> splitTopLevel(String data, String sep) {
  if (data.isEmpty) return <String>[''];
  final parts = <String>[];
  var depth = 0;
  var inSingle = false;
  var inDouble = false;
  var last = 0;
  var i = 0;
  while (i < data.length) {
    final c = data[i];
    if (c == '\\' && i + 1 < data.length) {
      i += 2;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (!inSingle && !inDouble) {
      if (c == '[' || c == '(') {
        depth++;
      } else if (c == ']' || c == ')') {
        if (depth > 0) depth--;
      }
      if (depth == 0 && data.startsWith(sep, i)) {
        parts.add(data.substring(last, i));
        i += sep.length;
        last = i;
        continue;
      }
    }
    i++;
  }
  parts.add(data.substring(last));
  return parts;
}

/// 去掉规则前导的 `@` 与空白（Kotlin `RuleAnalyzer.trim()`）。
String trimRulePrefix(String s) {
  var i = 0;
  while (i < s.length && (s[i] == '@' || s.codeUnitAt(i) < 0x21)) {
    i++;
  }
  return i == 0 ? s : s.substring(i);
}

int _findTopLevel(String data, String sep) {
  var depth = 0;
  var inSingle = false;
  var inDouble = false;
  var i = 0;
  while (i < data.length) {
    final c = data[i];
    if (c == '\\' && i + 1 < data.length) {
      i += 2;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (!inSingle && !inDouble) {
      if (c == '[' || c == '(') {
        depth++;
      } else if (c == ']' || c == ')') {
        if (depth > 0) depth--;
      }
      if (depth == 0 && data.startsWith(sep, i)) return i;
    }
    i++;
  }
  return -1;
}

/// 内嵌规则替换结果。[replaced] 表示是否命中过（命中但求值为空串也算命中）。
class InnerReplaceResult {
  const InnerReplaceResult(this.replaced, this.value);
  final bool replaced;
  final String value;
}

/// 替换 `{{js}}`（可嵌套结构、JS 里可含 `}`）。
///
/// 命中但求值为空串时**必须**替换成空串 —— 狼人小说 `exploreUrl` 的
/// `/allbook{{page === 1 ? '' : '_15155_' + page}}.html` 依赖这一点，
/// 否则首页会请求到带花括号的原串（404）。
Future<InnerReplaceResult> replaceDoubleBrace(
  String data,
  Future<String> Function(String inner) fn,
) async {
  var i = 0;
  var last = 0;
  var replaced = false;
  final out = StringBuffer();
  while (true) {
    final idx = data.indexOf('{{', i);
    if (idx < 0) break;
    final end = _matchBrace(data, idx + 2);
    if (end < 0) break;
    final inner = data.substring(idx + 2, end);
    final value = await fn(inner);
    out.write(data.substring(last, idx));
    out.write(value);
    last = end + 2;
    i = last;
    replaced = true;
  }
  if (!replaced) return InnerReplaceResult(false, '');
  out.write(data.substring(last));
  return InnerReplaceResult(true, out.toString());
}

/// 替换 JSON 内嵌规则 `{$.xxx}`。
Future<InnerReplaceResult> replaceInlineJsonRule(
  String data,
  Future<String> Function(String inner) fn,
) async {
  var i = 0;
  var last = 0;
  var replaced = false;
  final out = StringBuffer();
  while (true) {
    final idx = data.indexOf('{\$', i);
    if (idx < 0) break;
    final end = _matchBrace(data, idx + 1);
    if (end < 0) break;
    final inner = data.substring(idx + 1, end);
    final value = await fn(inner);
    out.write(data.substring(last, idx));
    out.write(value);
    last = end + 1;
    i = last;
    replaced = true;
  }
  if (!replaced) return InnerReplaceResult(false, '');
  out.write(data.substring(last));
  return InnerReplaceResult(true, out.toString());
}

/// 从 [start]（第一个字符视为花括号内部）找配对的 `}` 下标，找不到返回 -1。
int _matchBrace(String s, int start) {
  var depth = 0;
  var inSingle = false;
  var inDouble = false;
  var i = start;
  while (i < s.length) {
    final c = s[i];
    if (c == '\\') {
      i += 2;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (!inSingle && !inDouble) {
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        if (depth == 0) return i;
        depth--;
      }
    }
    i++;
  }
  return -1;
}
