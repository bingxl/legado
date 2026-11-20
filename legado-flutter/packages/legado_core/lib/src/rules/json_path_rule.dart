/// JSONPath 子集。
///
/// 语义以 Go 版 `pkg/rule/jsonpath.go` 为准（它修过几个只在数据上表现、
/// 不报错的坑）：
/// 1. 规则不以 `$` 开头时自动补前缀；`.[?(...)]` 补成 `$..[?(...)]`，
///    即**递归下降过滤** —— 纯 API 书源用一条规则同时捞嵌套列表靠的就是它；
/// 2. `$.` 后直接跟 `[`（`$.[*]`）是合法写法，归一化成 `$[*]`；
/// 3. 末尾聚合函数 `.length() .min() .max() .sum() .avg()`（jayway 有，原生 JSONPath 库普遍没有）；
/// 4. 结果里是数组时按元素展开，取单个值时数组用换行连接。
library;

import 'dart:convert';

import 'rule_splitter.dart';

/// JSONPath 规则解析（对齐 `AnalyzeByJSonPath.kt`）。
class JsonPathRule {
  JsonPathRule(Object content) {
    if (content is String) {
      _data = _decode(content);
    } else {
      _data = content;
    }
  }

  Object? _data;

  /// 读取路径命中的所有值。
  List<Object?> read(String path) {
    if (path.trim().isEmpty) return const [];
    final p = normalizePath(path);

    // 尾部聚合函数
    final funcMatch =
        RegExp(r'\.(length|min|max|avg|sum)\(\)$').firstMatch(p);
    if (funcMatch != null) {
      final base = p.substring(0, p.length - funcMatch.group(0)!.length);
      final vals = _readPath(_data, base);
      return _applyFunc(funcMatch.group(1)!, vals);
    }
    return _readPath(_data, p);
  }

  /// 等价 `getString`：多值换行连接，无命中返回空串。
  String getString(String path) {
    if (path.isEmpty) return '';
    final split = splitCombinator(path, const ['&&', '||']);
    if (split.parts.length > 1) {
      final texts = <String>[];
      for (final part in split.parts) {
        final t = getString(part);
        if (t.isNotEmpty) {
          texts.add(t);
          if (split.type == '||') break;
        }
      }
      return texts.join('\n');
    }
    final inline = split.parts[0];
    final inner = _replaceInlineRule(inline);
    if (inner != null) return inner;
    final vals = read(path);
    if (vals.isEmpty) return '';
    if (vals.length == 1) return valueToString(vals.first);
    return vals.map(valueToString).join('\n');
  }

  /// 等价 `getStringList`。
  List<String> getStringList(String path) {
    if (path.isEmpty) return <String>[];
    final split = splitCombinator(path, const ['&&', '||', '%%']);
    if (split.parts.length > 1) {
      final results = <List<String>>[];
      for (final part in split.parts) {
        final t = getStringList(part);
        if (t.isNotEmpty) {
          results.add(t);
          if (split.type == '||') break;
        }
      }
      if (split.type == '%%') {
        final out = <String>[];
        if (results.isEmpty) return out;
        for (var i = 0; i < results[0].length; i++) {
          for (final r in results) {
            if (i < r.length) out.add(r[i]);
          }
        }
        return out;
      }
      return [for (final r in results) ...r];
    }
    final inline = _replaceInlineRule(path);
    if (inline != null) return <String>[inline];
    return read(path).map(valueToString).toList();
  }

  /// 等价 `getObject`：取第一个命中值。
  Object? getObject(String path) {
    final vals = read(path);
    return vals.isEmpty ? null : vals.first;
  }

  /// 等价 `getList`：命中值是数组时展开。
  List<Object?> getList(String path) {
    if (path.trim().isEmpty) return <Object?>[];
    final split = splitCombinator(path, const ['&&', '||', '%%']);
    if (split.parts.length > 1) {
      final results = <List<Object?>>[];
      for (final part in split.parts) {
        final t = getList(part);
        if (t.isNotEmpty) {
          results.add(t);
          if (split.type == '||') break;
        }
      }
      if (split.type == '%%') {
        final out = <Object?>[];
        if (results.isEmpty) return out;
        for (var i = 0; i < results[0].length; i++) {
          for (final r in results) {
            if (i < r.length) out.add(r[i]);
          }
        }
        return out;
      }
      return [for (final r in results) ...r];
    }
    final vals = read(path);
    if (vals.length == 1 && vals.first is List) {
      return List<Object?>.from(vals.first as List);
    }
    return vals;
  }

  /// 内嵌规则 `{$.xxx}`：命中且替换成功时返回整串，否则 null。
  String? _replaceInlineRule(String rule) {
    if (!rule.contains('{\$')) return null;
    // 同步替换：内嵌规则同样是 JSONPath，递归走 read
    final sb = StringBuffer();
    var i = 0;
    var replaced = false;
    while (true) {
      final idx = rule.indexOf('{\$', i);
      if (idx < 0) break;
      final end = _matchBrace(rule, idx + 1);
      if (end < 0) break;
      final inner = rule.substring(idx + 1, end);
      final value = getString(inner);
      sb.write(rule.substring(i, idx));
      sb.write(value);
      i = end + 1;
      replaced = true;
    }
    if (!replaced) return null;
    sb.write(rule.substring(i));
    return sb.toString();
  }

  int _matchBrace(String s, int start) {
    var depth = 0;
    for (var i = start; i < s.length; i++) {
      final c = s[i];
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        if (depth == 0) return i;
        depth--;
      }
    }
    return -1;
  }

  Object? _decode(String text) {
    final t = text.trim();
    try {
      return jsonDecode(t);
    } catch (_) {
      return null;
    }
  }
}

/// 路径归一化（Go `normalizeJSONPath`）。
///
/// 关键点：不以 `$` 开头时补的是 `$.`（**不是** `$`）。
/// `.[?(@.title)]` 因此变成 `$..[?(@.title)]` —— 递归下降过滤，
/// 纯 API 书源（UAA 系）靠它一条规则同时捞嵌套列表。
String normalizePath(String path) {
  var p = path.trim();
  if (!p.startsWith('\$')) {
    p = '\$.$p';
  }
  // `$.[` → `$[`（`$..[` 不受影响：它是递归下降，不是多余点号）
  p = p.replaceAll(RegExp(r'\$\.\['), '\$[');
  // `[@.` → `[?(@.`（部分书源省略了 `?`）
  p = p.replaceAll(RegExp(r'\[@\.'), '[?(@.');
  return p;
}

List<Object?> _readPath(Object? data, String path) {
  if (data == null) return const [];
  final segs = _parsePath(path);
  var current = <Object?>[data];
  for (final seg in segs) {
    if (current.isEmpty) return const [];
    final next = <Object?>[];
    for (final v in current) {
      next.addAll(_applySeg(seg, v));
    }
    current = next;
  }
  // 过滤掉不存在的标记
  return current;
}

// —— 段解析 ——

sealed class _Seg {
  const _Seg();
}

class _NameSeg extends _Seg {
  const _NameSeg(this.name, {this.recursive = false});
  final String name;
  final bool recursive;
}

class _WildSeg extends _Seg {
  const _WildSeg({this.recursive = false});
  final bool recursive;
}

class _IndexSeg extends _Seg {
  const _IndexSeg(this.index);
  final int index;
}

class _SliceSeg extends _Seg {
  const _SliceSeg(this.start, this.end, this.step);
  final int? start;
  final int? end;
  final int? step;
}

class _UnionSeg extends _Seg {
  const _UnionSeg(this.items);
  final List<_Seg> items;
}

class _FilterSeg extends _Seg {
  const _FilterSeg(this.expr, {this.recursive = false});
  final String expr;
  final bool recursive;
}

class _RecursiveSeg extends _Seg {
  const _RecursiveSeg();
}

List<_Seg> _parsePath(String path) {
  final segs = <_Seg>[];
  var i = 0;
  final n = path.length;
  if (i < n && path[i] == '\$') i++;
  while (i < n) {
    final c = path[i];
    if (c == '.') {
      var recursive = false;
      i++;
      if (i < n && path[i] == '.') {
        recursive = true;
        i++;
      }
      if (i < n && path[i] == '[') {
        final end = _matchBracket(path, i);
        if (end < 0) break;
        final inner = path.substring(i + 1, end).trim();
        segs.add(_parseBracket(inner, recursive));
        i = end + 1;
        continue;
      }
      // 名字或 *
      final start = i;
      while (i < n && path[i] != '.' && path[i] != '[') {
        i++;
      }
      final name = path.substring(start, i).trim();
      if (name == '*') {
        segs.add(_WildSeg(recursive: recursive));
      } else if (name.isNotEmpty) {
        segs.add(_NameSeg(name, recursive: recursive));
      }
      continue;
    }
    if (c == '[') {
      final end = _matchBracket(path, i);
      if (end < 0) break;
      final inner = path.substring(i + 1, end).trim();
      segs.add(_parseBracket(inner, false));
      i = end + 1;
      continue;
    }
    // 兜底：按名字读取
    final start = i;
    while (i < n && path[i] != '.' && path[i] != '[') {
      i++;
    }
    final name = path.substring(start, i).trim();
    if (name.isNotEmpty && name != '\$') segs.add(_NameSeg(name));
  }
  return segs;
}

_Seg _parseBracket(String inner, bool recursive) {
  if (inner.isEmpty) return const _WildSeg();
  if (inner == '*') return _WildSeg(recursive: recursive);
  if (inner.startsWith('?')) {
    return _FilterSeg(
      inner.substring(1).trim(),
      recursive: recursive,
    );
  }
  if (inner.startsWith('(')) {
    return _FilterSeg(inner, recursive: recursive);
  }
  // 引号键：['a'] ["a"]
  if (inner.startsWith("'") || inner.startsWith('"')) {
    final items = _splitTopLevel(inner, ',');
    if (items.length > 1) {
      return _UnionSeg(items.map((e) => _parseBracket(e.trim(), recursive)).toList());
    }
    return _NameSeg(_unquote(inner), recursive: recursive);
  }
  // 切片 1:3 或 1:3:2
  if (inner.contains(':')) {
    final segs = inner.split(':');
    final start = segs[0].trim().isEmpty ? null : int.tryParse(segs[0].trim());
    final end = segs.length > 1 && segs[1].trim().isNotEmpty
        ? int.tryParse(segs[1].trim())
        : null;
    final step = segs.length > 2 && segs[2].trim().isNotEmpty
        ? int.tryParse(segs[2].trim())
        : null;
    return _SliceSeg(start, end, step);
  }
  // 联合 [0,2] / [0,'a']
  final items = _splitTopLevel(inner, ',');
  if (items.length > 1) {
    return _UnionSeg(items.map((e) => _parseBracket(e.trim(), recursive)).toList());
  }
  final idx = int.tryParse(inner.trim());
  if (idx != null) return _IndexSeg(idx);
  return _NameSeg(_unquote(inner.trim()), recursive: recursive);
}

String _unquote(String s) {
  var t = s.trim();
  if (t.length >= 2 &&
      ((t.startsWith("'") && t.endsWith("'")) ||
          (t.startsWith('"') && t.endsWith('"')))) {
    t = t.substring(1, t.length - 1);
  }
  return t;
}

List<String> _splitTopLevel(String s, String sep) {
  final out = <String>[];
  var depth = 0;
  var inSingle = false;
  var inDouble = false;
  var last = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c == '\\') {
      i++;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (!inSingle && !inDouble) {
      if (c == '[' || c == '(') depth++;
      if (c == ']' || c == ')') depth--;
      if (depth == 0 && s.startsWith(sep, i)) {
        out.add(s.substring(last, i));
        i += sep.length - 1;
        last = i + 1;
      }
    }
  }
  out.add(s.substring(last));
  return out;
}

int _matchBracket(String s, int open) {
  var depth = 0;
  var inSingle = false;
  var inDouble = false;
  for (var i = open; i < s.length; i++) {
    final c = s[i];
    if (c == '\\') {
      i++;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
    } else if (c == '"' && !inSingle) {
      inDouble = !inDouble;
    } else if (!inSingle && !inDouble) {
      if (c == '[') depth++;
      if (c == ']') {
        depth--;
        if (depth == 0) return i;
      }
    }
  }
  return -1;
}

// —— 段求值 ——

List<Object?> _applySeg(_Seg seg, Object? value) {
  if (value == null) return const [];
  switch (seg) {
    case _NameSeg(:final name, :final recursive):
      if (recursive) {
        final out = <Object?>[];
        for (final map in _descendantMaps(value)) {
          if (map.containsKey(name)) out.add(map[name]);
        }
        return out;
      }
      final map = _asMap(value);
      if (map != null && map.containsKey(name)) return <Object?>[map[name]];
      return const [];
    case _WildSeg(:final recursive):
      if (recursive) {
        final out = <Object?>[];
        _collectAll(value, out, includeSelf: false);
        return out;
      }
      if (value is List) return List<Object?>.from(value);
      if (value is Map) return List<Object?>.from(value.values);
      return const [];
    case _IndexSeg(:final index):
      if (value is List) {
        final i = index < 0 ? value.length + index : index;
        if (i >= 0 && i < value.length) return <Object?>[value[i]];
      }
      return const [];
    case _SliceSeg(:final start, :final end, :final step):
      if (value is! List) return const [];
      final len = value.length;
      var s = start ?? 0;
      if (s < 0) s += len;
      var e = end ?? len;
      if (e < 0) e += len;
      s = s.clamp(0, len);
      e = e.clamp(0, len);
      var st = step ?? 1;
      if (st == 0) st = 1;
      final out = <Object?>[];
      if (st > 0) {
        for (var i = s; i < e; i += st) {
          if (i >= 0 && i < len) out.add(value[i]);
        }
      } else {
        for (var i = e - 1; i >= s; i += st) {
          if (i >= 0 && i < len) out.add(value[i]);
        }
      }
      return out;
    case _UnionSeg(:final items):
      final out = <Object?>[];
      for (final item in items) {
        out.addAll(_applySeg(item, value));
      }
      return out;
    case _FilterSeg(:final expr, :final recursive):
      final out = <Object?>[];
      if (recursive) {
        final all = <Object?>[];
        _collectAll(value, all, includeSelf: true);
        for (final item in all) {
          if (_FilterExpr(expr).matches(item)) out.add(item);
        }
        return out;
      }
      if (value is List) {
        for (final item in value) {
          if (_FilterExpr(expr).matches(item)) out.add(item);
        }
        return out;
      }
      if (value is Map) {
        if (_FilterExpr(expr).matches(value)) out.add(value);
        return out;
      }
      return const [];
    case _RecursiveSeg():
      final out = <Object?>[];
      _collectAll(value, out, includeSelf: false);
      return out;
  }
}

Map<String, Object?>? _asMap(Object? v) {
  if (v is Map) return v.cast<String, Object?>();
  return null;
}

/// 序列化所有 Map 节点（含自身），用于递归下降。
List<Map<String, Object?>> _descendantMaps(Object? value) {
  final out = <Map<String, Object?>>[];
  void walk(Object? v) {
    if (v is Map) {
      out.add(v.cast<String, Object?>());
      for (final child in v.values) {
        walk(child);
      }
    } else if (v is List) {
      for (final child in v) {
        walk(child);
      }
    }
  }

  walk(value);
  return out;
}

void _collectAll(Object? value, List<Object?> out, {required bool includeSelf}) {
  void walk(Object? v) {
    if (v is Map) {
      for (final child in v.values) {
        out.add(child);
        walk(child);
      }
    } else if (v is List) {
      for (final child in v) {
        out.add(child);
        walk(child);
      }
    }
  }

  if (includeSelf) {
    if (value is Map || value is List) {
      // 自身也算候选（`$..[?(@.title)]` 命中根对象的情况）
      out.add(value);
    }
  }
  walk(value);
}

List<Object?> _applyFunc(String name, List<Object?> vals) {
  if (vals.isEmpty) return const [];
  if (name == 'length') {
    if (vals.length == 1) {
      final n = _lengthOf(vals.first);
      if (n != null) return <Object?>[n];
    }
    return <Object?>[vals.length];
  }
  final nums = <num>[];
  if (vals.length == 1 && vals.first is List) {
    for (final x in vals.first as List) {
      final n = _toNum(x);
      if (n != null) nums.add(n);
    }
  }
  if (nums.isEmpty) {
    for (final x in vals) {
      final n = _toNum(x);
      if (n != null) nums.add(n);
    }
  }
  if (nums.isEmpty) return const [];
  switch (name) {
    case 'min':
      return <Object?>[nums.reduce((a, b) => a < b ? a : b)];
    case 'max':
      return <Object?>[nums.reduce((a, b) => a > b ? a : b)];
    case 'sum':
      return <Object?>[nums.reduce((a, b) => a + b)];
    case 'avg':
      return <Object?>[nums.reduce((a, b) => a + b) / nums.length];
  }
  return const [];
}

int? _lengthOf(Object? v) {
  if (v is List) return v.length;
  if (v is Map) return v.length;
  if (v is String) return v.runes.length;
  return null;
}

num? _toNum(Object? v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

/// 值字符串化：字符串原样，整数不带 `.0`，对象/数组用 JSON。
String valueToString(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is num) {
    if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
      return v.toInt().toString();
    }
    return v.toString();
  }
  if (v is bool) return v.toString();
  if (v is Map || v is List) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return v.toString();
    }
  }
  return v.toString();
}

// —— 过滤器表达式 ——

/// 过滤器求值：`@.a`、`@.a=='v'`、`@.a>1`、`@.a=~/re/`、`&&`/`||`/`!`/括号。
class _FilterExpr {
  _FilterExpr(this.src) {
    _tokens = _tokenizeFilter(src);
  }

  final String src;
  late final List<_FToken> _tokens;
  int _pos = 0;

  bool matches(Object? candidate) {
    _pos = 0;
    _candidate = candidate;
    if (_tokens.isEmpty) return false;
    return _truthy(_parseOr());
  }

  Object? _candidate;
  _FToken? get _cur => _pos < _tokens.length ? _tokens[_pos] : null;

  bool _eat(String t) {
    final c = _cur;
    if (c != null && c.text == t) {
      _pos++;
      return true;
    }
    return false;
  }

  Object? _parseOr() {
    var left = _parseAnd();
    while (_eat('||') || _eat('or')) {
      final right = _parseAnd();
      left = _truthy(left) || _truthy(right);
    }
    return left;
  }

  Object? _parseAnd() {
    var left = _parseUnary();
    while (_eat('&&') || _eat('and')) {
      final right = _parseUnary();
      left = _truthy(left) && _truthy(right);
    }
    return left;
  }

  Object? _parseUnary() {
    if (_eat('!')) return !_truthy(_parseUnary());
    if (_eat('(')) {
      final v = _parseOr();
      _eat(')');
      return v;
    }
    return _parseCmp();
  }

  Object? _parseCmp() {
    final left = _parsePrimary();
    final c = _cur;
    if (c == null) return left;
    const ops = ['==', '!=', '>=', '<=', '=~', '>', '<', '='];
    for (final op in ops) {
      if (c.text == op) {
        _pos++;
        final right = _parsePrimary();
        return _compare(left, right, op);
      }
    }
    return left;
  }

  Object? _parsePrimary() {
    final c = _cur;
    if (c == null) return null;
    if (c.kind == _FTokKind.string) {
      _pos++;
      return c.text;
    }
    if (c.kind == _FTokKind.number) {
      _pos++;
      return num.tryParse(c.text);
    }
    if (c.kind == _FTokKind.regex) {
      _pos++;
      return _RegexValue(c.text, c.extra ?? '');
    }
    if (c.kind == _FTokKind.at) {
      _pos++;
      // @.a.b / @['a']
      Object? current = _candidate;
      while (true) {
        if (_eat('.')) {
          final nameTok = _cur;
          if (nameTok == null) break;
          _pos++;
          if (nameTok.text == '*') continue;
          current = _child(current, nameTok.text);
          continue;
        }
        if (_eat('[')) {
          final keyTok = _cur;
          if (keyTok == null) break;
          _pos++;
          current = _child(current, keyTok.text);
          _eat(']');
          continue;
        }
        break;
      }
      return current;
    }
    if (c.kind == _FTokKind.name) {
      _pos++;
      final lower = c.text.toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
      if (lower == 'null') return null;
      return c.text;
    }
    _pos++;
    return c.text;
  }

  Object? _child(Object? current, String key) {
    if (current is Map) return current[key];
    if (current is List) {
      if (key == 'length' || key == 'size') return current.length;
      final i = int.tryParse(key);
      if (i != null && i >= 0 && i < current.length) return current[i];
    }
    if (current is String && (key == 'length' || key == 'size')) {
      return current.length;
    }
    return null;
  }

  Object? _compare(Object? a, Object? b, String op) {
    if (op == '=~') {
      final re = b is _RegexValue ? b : _RegexValue(b.toString(), '');
      final text = a?.toString() ?? '';
      try {
        return RegExp(re.pattern, caseSensitive: !re.ignoreCase).hasMatch(text);
      } catch (_) {
        return false;
      }
    }
    if (op == '==' || op == '=') return _equals(a, b);
    if (op == '!=') return !_equals(a, b);
    final na = _toNum(a);
    final nb = _toNum(b);
    if (na != null && nb != null) {
      switch (op) {
        case '>':
          return na > nb;
        case '<':
          return na < nb;
        case '>=':
          return na >= nb;
        case '<=':
          return na <= nb;
      }
    }
    final sa = a?.toString() ?? '';
    final sb = b?.toString() ?? '';
    switch (op) {
      case '>':
        return sa.compareTo(sb) > 0;
      case '<':
        return sa.compareTo(sb) < 0;
      case '>=':
        return sa.compareTo(sb) >= 0;
      case '<=':
        return sa.compareTo(sb) <= 0;
    }
    return false;
  }

  bool _equals(Object? a, Object? b) {
    if (a == null && b == null) return true;
    if (a is num && b is num) return a == b;
    final na = a is num ? a : null;
    final nb = b is num ? b : null;
    if (na != null && nb != null) return na == nb;
    // 字符串与数字混比：按数值比
    if (a is num && b is String) {
      final parsed = num.tryParse(b.trim());
      if (parsed != null) return a == parsed;
    }
    if (a is String && b is num) {
      final parsed = num.tryParse(a.trim());
      if (parsed != null) return parsed == b;
    }
    return a?.toString() == b?.toString();
  }
}

class _RegexValue {
  const _RegexValue(this.pattern, this.flags);
  final String pattern;
  final String flags;
  bool get ignoreCase => flags.contains('i');
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v.isNotEmpty;
  if (v is List) return v.isNotEmpty;
  if (v is Map) return v.isNotEmpty;
  return true;
}

enum _FTokKind { at, string, number, regex, name, symbol }

class _FToken {
  const _FToken(this.kind, this.text, [this.extra]);
  final _FTokKind kind;
  final String text;
  final String? extra;
}

List<_FToken> _tokenizeFilter(String s) {
  final out = <_FToken>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.trim().isEmpty) {
      i++;
      continue;
    }
    if (c == '@') {
      out.add(const _FToken(_FTokKind.at, '@'));
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      final quote = c;
      var j = i + 1;
      final sb = StringBuffer();
      while (j < s.length && s[j] != quote) {
        if (s[j] == '\\' && j + 1 < s.length) {
          sb.write(s[j + 1]);
          j += 2;
          continue;
        }
        sb.write(s[j]);
        j++;
      }
      out.add(_FToken(_FTokKind.string, sb.toString()));
      i = j + 1;
      continue;
    }
    if (c == '/' && (out.isEmpty || out.last.text == '=~' || out.last.text == '(')) {
      // 正则字面量
      var j = i + 1;
      final sb = StringBuffer();
      while (j < s.length && s[j] != '/') {
        if (s[j] == '\\' && j + 1 < s.length) {
          sb.write(s[j]);
          sb.write(s[j + 1]);
          j += 2;
          continue;
        }
        sb.write(s[j]);
        j++;
      }
      var flags = '';
      j++;
      while (j < s.length && RegExp(r'[a-zA-Z]').hasMatch(s[j])) {
        flags += s[j];
        j++;
      }
      out.add(_FToken(_FTokKind.regex, sb.toString(), flags));
      i = j;
      continue;
    }
    if (RegExp(r'[0-9\-]').hasMatch(c) &&
        (i == 0 || !RegExp(r'[A-Za-z0-9_]').hasMatch(s[i - 1]))) {
      var j = i + 1;
      while (j < s.length && RegExp(r'[0-9.]').hasMatch(s[j])) {
        j++;
      }
      out.add(_FToken(_FTokKind.number, s.substring(i, j)));
      i = j;
      continue;
    }
    if (RegExp(r'[A-Za-z_$]').hasMatch(c)) {
      var j = i;
      while (j < s.length && RegExp(r'[A-Za-z0-9_$]').hasMatch(s[j])) {
        j++;
      }
      out.add(_FToken(_FTokKind.name, s.substring(i, j)));
      i = j;
      continue;
    }
    if (i + 1 < s.length) {
      final two = s.substring(i, i + 2);
      if (const ['&&', '||', '==', '!=', '>=', '<=', '=~'].contains(two)) {
        out.add(_FToken(_FTokKind.symbol, two));
        i += 2;
        continue;
      }
    }
    out.add(_FToken(_FTokKind.symbol, c));
    i++;
  }
  return out;
}
