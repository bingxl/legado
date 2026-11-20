/// XPath 子集（运行在 `package:html` 的 DOM 上）。
///
/// 为什么不用 `package:xml` 的 XPath：真实书源的响应是**脏 HTML**
/// （未闭合标签、裸 `&`、重复属性），XML 解析器会直接抛异常。
/// 原版用 seimicrawler 的 JXDocument（内部也是 jsoup DOM + 自研 XPath），
/// 这里按同一思路实现一个够用的子集。
///
/// 覆盖：`//` `/` `.` `..`、`[n]` `[last()]` `[@a]` `[@a='v']`
/// `[contains()]` `[text()='v']` `[position()>n]`、`and`/`or`、`/@attr`、
/// `text()` `normalize-space()` `starts-with()` `string-length()` `concat()`
/// `substring-before()/after()` `not()` `count()`。
library;

import 'package:html/dom.dart' as dom;

import 'html_rule.dart';
import 'rule_splitter.dart';

/// XPath 结果节点。
sealed class XValue {
  const XValue();
  String asString();

  /// 元素节点（非元素返回 null）。
  dom.Element? get element => null;

  String? get attributeValue => null;
}

class XElementValue extends XValue {
  const XElementValue(this.node);
  final dom.Element node;

  @override
  dom.Element? get element => node;

  @override
  String asString() => jsoupText(node);
}

class XAttributeValue extends XValue {
  const XAttributeValue(this.name, this.value);
  final String name;
  final String value;

  @override
  String? get attributeValue => value;

  @override
  String asString() => value;
}

class XTextValue extends XValue {
  const XTextValue(this.value);
  final String value;

  @override
  String asString() => value;
}

/// XPath 规则解析（对齐 `AnalyzeByXPath.kt`）。
class XPathRule {
  XPathRule(Object content, {this.baseUrl = ''}) {
    if (content is dom.Element) {
      _root = content;
      _isDocument = false;
    } else if (content is dom.Document) {
      _root = content;
      _isDocument = true;
    } else {
      final doc = parseHtmlDocument(content.toString());
      _root = doc;
      _isDocument = true;
    }
  }

  final String baseUrl;
  late final dom.Node _root;
  late final bool _isDocument;

  /// 取节点列表。
  List<XValue> getNodes(String path) {
    if (path.trim().isEmpty) return <XValue>[];
    final split = splitCombinator(path, const ['&&', '||', '%%']);
    if (split.parts.length == 1) {
      return _select(path.trim());
    }
    final results = <List<XValue>>[];
    for (final part in split.parts) {
      final temp = _select(part.trim());
      if (temp.isNotEmpty) {
        results.add(temp);
        if (split.type == '||') break;
      }
    }
    return _merge(split.type, results);
  }

  /// 等价 `getStringList`。
  List<String> getStringList(String path) =>
      getNodes(path).map((e) => e.asString()).toList();

  /// 等价 `getString`：多节点用换行连接，空返回 null。
  String? getString(String path) {
    final split = splitCombinator(path, const ['&&', '||']);
    if (split.parts.length == 1) {
      final nodes = _select(path.trim());
      if (nodes.isEmpty) return null;
      return nodes.map((e) => e.asString()).join('\n');
    }
    final texts = <String>[];
    for (final part in split.parts) {
      final t = getString(part.trim());
      if (t != null && t.isNotEmpty) {
        texts.add(t);
        if (split.type == '||') break;
      }
    }
    return texts.join('\n');
  }

  List<XValue> _merge(String type, List<List<XValue>> results) {
    if (results.isEmpty) return <XValue>[];
    if (type == '%%') {
      final out = <XValue>[];
      for (var i = 0; i < results[0].length; i++) {
        for (final r in results) {
          if (i < r.length) out.add(r[i]);
        }
      }
      return out;
    }
    return [for (final r in results) ...r];
  }

  List<XValue> _select(String path) {
    final steps = _parsePath(path);
    if (steps.isEmpty) return <XValue>[];
    var current = <XValue>[
      if (_isDocument) XElementValue(_documentElement) else XElementValue(_root as dom.Element),
    ];
    var index = 0;
    for (final step in steps) {
      // `/html` 这类绝对路径的首步：上下文已是根元素，要把自身也算进候选
      final includeSelf = _isDocument &&
          index == 0 &&
          step is _AxisStep &&
          !step.descendant;
      final next = <XValue>[];
      for (final ctx in current) {
        next.addAll(_evalStep(step, ctx, includeSelf));
      }
      index++;
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  dom.Element get _documentElement {
    final root = _root;
    return root.nodes.whereType<dom.Element>().firstOrNull ??
        dom.Element.tag('html');
  }

  List<XValue> _evalStep(_Step step, XValue ctx, bool includeSelf) {
    switch (step) {
      case _SelfStep():
        return <XValue>[ctx];
      case _ParentStep():
        final el = ctx.element;
        final parent = el?.parent;
        return parent == null ? <XValue>[] : <XValue>[XElementValue(parent)];
      case _AttrStep(:final name):
        final el = ctx.element;
        if (el == null) return <XValue>[];
        if (!hasAttr(el, name)) return <XValue>[];
        return <XValue>[XAttributeValue(name, attrOf(el, name))];
      case _TextStep(:final descendant):
        final el = ctx.element;
        if (el == null) return <XValue>[];
        final out = <XValue>[];
        if (descendant) {
          void walk(dom.Node n) {
            for (final c in n.nodes) {
              if (c is dom.Text) {
                if (c.text.trim().isNotEmpty) out.add(XTextValue(c.text.trim()));
              } else if (c is dom.Element) {
                walk(c);
              }
            }
          }

          walk(el);
        } else {
          for (final c in el.nodes) {
            if (c is dom.Text && c.text.trim().isNotEmpty) {
              out.add(XTextValue(c.text.trim()));
            }
          }
        }
        return out;
      case _AxisStep(:final descendant, :final test, :final predicates):
        final el = ctx.element;
        if (el == null) return <XValue>[];
        final candidates = <dom.Element>[];
        if (descendant) {
          void walk(dom.Node n) {
            for (final c in n.nodes) {
              if (c is dom.Element) {
                candidates.add(c);
                walk(c);
              }
            }
          }

          walk(el);
        } else {
          if (includeSelf) candidates.add(el);
          candidates.addAll(el.children);
        }
        var filtered = candidates.where((e) => _testName(e, test)).toList();
        for (final pred in predicates) {
          filtered = _applyPredicate(filtered, pred);
        }
        return filtered.map<XValue>(XElementValue.new).toList();
    }
  }

  bool _testName(dom.Element e, String test) {
    if (test == '*' || test.isEmpty) return true;
    var name = test;
    final colon = name.indexOf(':');
    if (colon >= 0) name = name.substring(colon + 1);
    return (e.localName ?? '').toLowerCase() == name.toLowerCase();
  }

  List<dom.Element> _applyPredicate(List<dom.Element> nodes, _Predicate pred) {
    final out = <dom.Element>[];
    final size = nodes.length;
    for (var i = 0; i < nodes.length; i++) {
      final pos = i + 1;
      if (pred.isIndex) {
        final n = pred.index!;
        if (n == pos) out.add(nodes[i]);
        continue;
      }
      if (pred.isLast) {
        if (pos == size) out.add(nodes[i]);
        continue;
      }
      final hit = _ExprParser(pred.expr!, nodes[i], pos, size).evaluateBool();
      if (hit) out.add(nodes[i]);
    }
    return out;
  }
}

// —— 路径解析 ——

sealed class _Step {
  const _Step();
}

class _SelfStep extends _Step {
  const _SelfStep();
}

class _ParentStep extends _Step {
  const _ParentStep();
}

class _AttrStep extends _Step {
  const _AttrStep(this.name);
  final String name;
}

class _TextStep extends _Step {
  const _TextStep({required this.descendant});
  final bool descendant;
}

class _AxisStep extends _Step {
  const _AxisStep(this.descendant, this.test, this.predicates);
  final bool descendant;
  final String test;
  final List<_Predicate> predicates;
}

class _Predicate {
  const _Predicate.index(this.index)
      : isIndex = true,
        isLast = false,
        expr = null;

  const _Predicate.last()
      : isIndex = false,
        isLast = true,
        index = null,
        expr = null;

  const _Predicate.expr(this.expr)
      : isIndex = false,
        isLast = false,
        index = null;

  final bool isIndex;
  final bool isLast;
  final int? index;
  final String? expr;
}

List<_Step> _parsePath(String path) {
  final steps = <_Step>[];
  var i = 0;
  final n = path.length;
  var descendant = false;
  var first = true;

  // 跳过开头的 './'
  while (i < n && path[i].trim().isEmpty) {
    i++;
  }
  while (i < n) {
    if (path[i] == '/') {
      if (i + 1 < n && path[i + 1] == '/') {
        descendant = true;
        i += 2;
      } else {
        descendant = false;
        i++;
      }
      first = false;
      continue;
    }
    if (path[i] == '.' && i + 1 < n && path[i + 1] == '/') {
      i += 2;
      first = false;
      descendant = false;
      continue;
    }
    final start = i;
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    while (i < n) {
      final c = path[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (c == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (c == '[' || c == '(') depth++;
        if (c == ']' || c == ')') depth--;
        if (depth == 0 && c == '/') break;
      }
      i++;
    }
    final text = path.substring(start, i).trim();
    if (text.isNotEmpty) {
      final step = _parseStep(text, descendant && !first);
      if (step != null) steps.add(step);
    }
    // 开头的 `//` 对大根来说也是「后代」，但记录在下一个 step 上
    descendant = false;
    first = false;
  }
  return steps;
}

_Step? _parseStep(String text, bool descendant) {
  if (text == '.') return const _SelfStep();
  if (text == '..') return const _ParentStep();
  if (text == 'text()') return _TextStep(descendant: descendant);
  if (text == 'node()') return _TextStep(descendant: descendant);
  if (text.startsWith('@')) {
    final name = text.substring(1).trim();
    if (name.isEmpty) return null;
    return _AttrStep(name);
  }
  // 名字 + 谓词
  var i = 0;
  final preds = <_Predicate>[];
  String? name;
  final n = text.length;
  while (i < n) {
    if (text[i] == '[') {
      final end = _matchBracket(text, i);
      if (end < 0) break;
      preds.add(_parsePredicate(text.substring(i + 1, end).trim()));
      i = end + 1;
      continue;
    }
    final start = i;
    while (i < n && text[i] != '[') {
      i++;
    }
    name = text.substring(start, i).trim();
  }
  name ??= text.trim();
  if (name.isEmpty) name = '*';
  return _AxisStep(descendant, name, preds);
}

_Predicate _parsePredicate(String p) {
  final n = int.tryParse(p);
  if (n != null) return _Predicate.index(n);
  if (p == 'last()') return const _Predicate.last();
  return _Predicate.expr(p);
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

// —— 表达式求值 ——

class _ExprParser {
  _ExprParser(this.src, this.node, this.position, this.size) {
    _tokens = _tokenize(src);
  }

  final String src;
  final dom.Element node;
  final int position;
  final int size;
  late final List<_Token> _tokens;
  int _pos = 0;

  bool evaluateBool() {
    final v = _parseOr();
    return _truthy(v);
  }

  _Token? get _cur => _pos < _tokens.length ? _tokens[_pos] : null;

  bool _eat(String text) {
    final c = _cur;
    if (c != null && c.text == text) {
      _pos++;
      return true;
    }
    return false;
  }

  bool _eatKeyword(String kw) {
    final c = _cur;
    if (c != null && c.kind == _TokKind.name && c.text.toLowerCase() == kw) {
      _pos++;
      return true;
    }
    return false;
  }

  Object? _parseOr() {
    var left = _parseAnd();
    while (_eatKeyword('or') || _eat('||')) {
      final right = _parseAnd();
      left = _truthy(left) || _truthy(right);
    }
    return left;
  }

  Object? _parseAnd() {
    var left = _parseCmp();
    while (_eatKeyword('and') || _eat('&&')) {
      final right = _parseCmp();
      left = _truthy(left) && _truthy(right);
    }
    return left;
  }

  Object? _parseCmp() {
    final left = _parseUnary();
    final c = _cur;
    if (c == null) return left;
    const ops = ['!=', '<=', '>=', '=', '<', '>'];
    for (final op in ops) {
      if (c.text == op) {
        _pos++;
        final right = _parseUnary();
        return _compare(left, right, op);
      }
    }
    return left;
  }

  Object? _parseUnary() {
    if (_eat('-')) {
      final v = _parseUnary();
      return -_num(v);
    }
    return _parsePrimary();
  }

  Object? _parsePrimary() {
    final c = _cur;
    if (c == null) return '';
    if (c.text == '(') {
      _pos++;
      final v = _parseOr();
      _eat(')');
      return v;
    }
    if (c.kind == _TokKind.string) {
      _pos++;
      return c.text;
    }
    if (c.kind == _TokKind.number) {
      _pos++;
      return num.tryParse(c.text) ?? 0;
    }
    if (c.text == '@') {
      _pos++;
      final nameTok = _cur;
      if (nameTok == null) return <XValue>[];
      _pos++;
      if (!hasAttr(node, nameTok.text)) return <XValue>[];
      return <XValue>[XAttributeValue(nameTok.text, attrOf(node, nameTok.text))];
    }
    if (c.text == '.') {
      _pos++;
      return <XValue>[XElementValue(node)];
    }
    if (c.text == '..') {
      _pos++;
      final parent = node.parent;
      return parent == null ? <XValue>[] : <XValue>[XElementValue(parent)];
    }
    if (c.kind == _TokKind.name) {
      final name = c.text;
      _pos++;
      if (_eat('(')) {
        final args = <Object?>[];
        if (!_eat(')')) {
          do {
            args.add(_parseOr());
          } while (_eat(','));
          _eat(')');
        }
        return _call(name, args);
      }
      // 子元素名
      return node.children
          .where((e) => (e.localName ?? '').toLowerCase() == name.toLowerCase())
          .map<XValue>(XElementValue.new)
          .toList();
    }
    _pos++;
    return '';
  }

  Object? _call(String name, List<Object?> args) {
    switch (name.toLowerCase()) {
      case 'text':
        final out = <XValue>[];
        for (final c in node.nodes) {
          if (c is dom.Text && c.text.trim().isNotEmpty) {
            out.add(XTextValue(c.text.trim()));
          }
        }
        return out;
      case 'normalize-space':
        return _str(args.isEmpty ? <XValue>[XElementValue(node)] : args[0])
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
      case 'string-length':
        return _str(args.isEmpty ? <XValue>[XElementValue(node)] : args[0]).length;
      case 'contains':
        return _str(_arg(args, 0)).contains(_str(_arg(args, 1)));
      case 'starts-with':
        return _str(_arg(args, 0)).startsWith(_str(_arg(args, 1)));
      case 'ends-with':
        return _str(_arg(args, 0)).endsWith(_str(_arg(args, 1)));
      case 'substring-before':
        final s = _str(_arg(args, 0));
        final sep = _str(_arg(args, 1));
        final i = s.indexOf(sep);
        return i < 0 ? '' : s.substring(0, i);
      case 'substring-after':
        final s = _str(_arg(args, 0));
        final sep = _str(_arg(args, 1));
        final i = s.indexOf(sep);
        return i < 0 ? '' : s.substring(i + sep.length);
      case 'concat':
        return args.map(_str).join();
      case 'not':
        return !_truthy(_arg(args, 0));
      case 'count':
        final v = _arg(args, 0);
        return v is List ? v.length : 1;
      case 'last':
        return size;
      case 'position':
        return position;
      case 'name':
        return node.localName ?? '';
      case 'string':
        return _str(args.isEmpty ? <XValue>[XElementValue(node)] : args[0]);
      case 'number':
        return _num(_arg(args, 0));
      case 'floor':
        return _num(_arg(args, 0)).floor();
      case 'ceiling':
        return _num(_arg(args, 0)).ceil();
    }
    return '';
  }

  Object? _arg(List<Object?> args, int i) => i < args.length ? args[i] : '';
}

Object? _compare(Object? a, Object? b, String op) {
  if (a is List || b is List) {
    final la = a is List ? a : <Object?>[a];
    final lb = b is List ? b : <Object?>[b];
    for (final x in la) {
      for (final y in lb) {
        if (_compareScalar(_str(x), _str(y), op)) return true;
      }
    }
    return false;
  }
  final na = a is num ? a : num.tryParse(a.toString());
  final nb = b is num ? b : num.tryParse(b.toString());
  if (na != null && nb != null) {
    switch (op) {
      case '=':
        return na == nb;
      case '!=':
        return na != nb;
      case '<':
        return na < nb;
      case '>':
        return na > nb;
      case '<=':
        return na <= nb;
      case '>=':
        return na >= nb;
    }
  }
  return _compareScalar(a.toString(), b.toString(), op);
}

bool _compareScalar(String a, String b, String op) {
  switch (op) {
    case '=':
      return a == b;
    case '!=':
      return a != b;
    case '<':
      return a.compareTo(b) < 0;
    case '>':
      return a.compareTo(b) > 0;
    case '<=':
      return a.compareTo(b) <= 0;
    case '>=':
      return a.compareTo(b) >= 0;
  }
  return false;
}

bool _truthy(Object? v) {
  if (v == null) return false;
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is List) return v.isNotEmpty;
  final s = v.toString();
  return s.isNotEmpty;
}

String _str(Object? v) {
  if (v == null) return '';
  if (v is List) {
    if (v.isEmpty) return '';
    final first = v.first;
    return first is XValue ? first.asString() : first.toString();
  }
  if (v is XValue) return v.asString();
  if (v is num) {
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    return v.toString();
  }
  return v.toString();
}

num _num(Object? v) {
  if (v is num) return v;
  return num.tryParse(_str(v).trim()) ?? 0;
}

enum _TokKind { name, number, string, symbol }

class _Token {
  const _Token(this.kind, this.text);
  final _TokKind kind;
  final String text;
}

List<_Token> _tokenize(String s) {
  final out = <_Token>[];
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c.trim().isEmpty) {
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
      out.add(_Token(_TokKind.string, sb.toString()));
      i = j + 1;
      continue;
    }
    if (RegExp(r'[0-9]').hasMatch(c)) {
      var j = i;
      while (j < s.length && RegExp(r'[0-9.]').hasMatch(s[j])) {
        j++;
      }
      out.add(_Token(_TokKind.number, s.substring(i, j)));
      i = j;
      continue;
    }
    if (RegExp(r'[A-Za-z_\-]').hasMatch(c)) {
      var j = i;
      while (j < s.length &&
          RegExp(r'[A-Za-z0-9_\-.·]').hasMatch(s[j])) {
        j++;
      }
      out.add(_Token(_TokKind.name, s.substring(i, j)));
      i = j;
      continue;
    }
    if (i + 1 < s.length) {
      final two = s.substring(i, i + 2);
      if (const ['!=', '<=', '>=', '&&', '||'].contains(two)) {
        out.add(_Token(_TokKind.symbol, two));
        i += 2;
        continue;
      }
    }
    out.add(_Token(_TokKind.symbol, c));
    i++;
  }
  return out;
}
