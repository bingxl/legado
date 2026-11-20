/// CSS 选择器引擎（jsoup 语义）。
///
/// 为什么不用 `package:html` 的 `querySelectorAll`：
/// 1. 它的 CSS 解析基于 csslib，遇到 jsoup 扩展伪类（`:eq(n)`、`:contains()`、
///    `:matches()`）会直接抛 `UnimplementedError`；
/// 2. 遇到书源里常见的裸值属性选择器（`a[href^=/1]`，值以 `/` 或数字开头）
///    csslib 解析失败；
/// 3. jsoup 的 `:eq(n)` 是按**兄弟节点下标**过滤，不是按匹配结果下标，
///    两者语义不同。
///
/// 所以这里在 `package:html` 的 DOM 上自研选择器：结构（标签/类/ID/属性/组合符）
/// 与标准 CSS 一致，伪类按 jsoup 的 `Evaluator` 实现补齐。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../util/url.dart';
import 'rule_splitter.dart';

/// 解析 HTML 字符串为 Document。
dom.Document parseHtmlDocument(String html) {
  var source = html;
  // XPath 场景下，单独一段 `<td>`/`<tr>` 会被 HTML 解析器丢掉，补齐外层容器
  // （对齐 Kotlin `AnalyzeByXPath.strToJXDocument`）。
  if (source.endsWith('</td>')) source = '<tr>$source</tr>';
  if (source.endsWith('</tr>') || source.endsWith('</tbody>')) {
    source = '<table>$source</table>';
  }
  return html_parser.parse(source);
}

/// 块级标签（jsoup 用它决定 `text()` 里是否补空格）。
const _blockTags = <String>{
  'html', 'body', 'div', 'p', 'ul', 'ol', 'li', 'table', 'tr', 'td', 'th',
  'tbody', 'thead', 'tfoot', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'dl', 'dt',
  'dd', 'blockquote', 'pre', 'section', 'article', 'header', 'footer', 'nav',
  'aside', 'form', 'fieldset', 'figure', 'figcaption', 'main', 'address',
  'center', 'details', 'summary', 'hr', 'textarea', 'caption', 'colgroup',
};

/// jsoup `Element.text()`：块级边界补空格，所有空白折叠为单个空格后 trim。
String jsoupText(dom.Node? node) {
  if (node == null) return '';
  final sb = StringBuffer();
  _collectText(node, sb);
  return _normalizeWhitespace(sb.toString());
}

/// jsoup `Element.ownText()`：只取直接文本子节点。
String jsoupOwnText(dom.Element? element) {
  if (element == null) return '';
  final sb = StringBuffer();
  for (final child in element.nodes) {
    if (child is dom.Text) sb.write(child.text);
  }
  return _normalizeWhitespace(sb.toString());
}

/// jsoup `Element.textNodes()`：直接文本子节点，逐个 trim 后返回。
List<String> jsoupTextNodes(dom.Element? element) {
  if (element == null) return const [];
  final out = <String>[];
  for (final child in element.nodes) {
    if (child is dom.Text) {
      final t = child.text.trim();
      if (t.isNotEmpty) out.add(t);
    }
  }
  return out;
}

void _collectText(dom.Node node, StringBuffer sb) {
  if (node is dom.Text) {
    sb.write(node.text);
    return;
  }
  if (node is! dom.Element) return;
  final tag = node.localName?.toLowerCase() ?? '';
  if (tag == 'script' || tag == 'style' || tag == 'template') return;
  if (tag == 'br') {
    sb.write(' ');
    return;
  }
  final block = _blockTags.contains(tag);
  if (block) _appendSpace(sb);
  for (final child in node.nodes) {
    _collectText(child, sb);
  }
  if (block) _appendSpace(sb);
}

void _appendSpace(StringBuffer sb) {
  if (sb.isEmpty) return;
  final s = sb.toString();
  if (s.isEmpty) return;
  final last = s.codeUnitAt(s.length - 1);
  if (last == 0x20 || last == 0x0A || last == 0x09) return;
  sb.write(' ');
}

String _normalizeWhitespace(String s) {
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const _namedEntities = <String, String>{
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'nbsp': '\u00a0',
  'ldquo': '“',
  'rdquo': '”',
  'lsquo': '‘',
  'rsquo': '’',
  'hellip': '…',
  'mdash': '—',
  'ndash': '–',
  'middot': '·',
  'times': '×',
  'copy': '©',
  'reg': '®',
};

/// HTML4 实体反转义（对齐 `StringEscapeUtils.unescapeHtml4`）。
///
/// 书源正文里 `&nbsp;` `&hellip;` 很常见，不解会把实体原样塞进书里。
String htmlUnescape4(String input) {
  if (!input.contains('&')) return input;
  return input.replaceAllMapped(
    RegExp(r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[A-Za-z][A-Za-z0-9]{1,31});'),
    (m) {
      final body = m.group(1)!;
      if (body.startsWith('#')) {
        final isHex = body.length > 1 && (body[1] == 'x' || body[1] == 'X');
        final numText = isHex ? body.substring(2) : body.substring(1);
        final code = int.tryParse(numText, radix: isHex ? 16 : 10);
        if (code == null || code < 0 || code > 0x10FFFF) return m.group(0)!;
        try {
          return String.fromCharCode(code);
        } catch (_) {
          return m.group(0)!;
        }
      }
      return _namedEntities[body.toLowerCase()] ?? m.group(0)!;
    },
  );
}

/// 取属性值（HTML 解析器会把属性名转小写，这里再兜一层）。
String attrOf(dom.Element element, String name) {
  final lower = name.toLowerCase();
  for (final entry in element.attributes.entries) {
    if (entry.key.toString().toLowerCase() == lower) return entry.value;
  }
  return '';
}

bool hasAttr(dom.Element element, String name) {
  final lower = name.toLowerCase();
  for (final key in element.attributes.keys) {
    if (key.toString().toLowerCase() == lower) return true;
  }
  return false;
}

/// 书源规则里的取值关键字（不是选择器）。
const _valueKeywords = <String>{
  'text',
  'textNodes',
  'ownText',
  'html',
  'all',
};

/// 判断一个只有一段的规则是「选择器」还是「属性名」（Go 版修过的坑）。
///
/// - `href` / `title` / `data-src` / `abs:href` → 属性名
/// - `li.col-4` / `.item` / `#list` / `tag.a[0]` / `a > b` → 选择器
bool isSelectorRule(String s) {
  final t = s.trim();
  if (t.isEmpty) return false;
  if (t.contains(RegExp(r'[ \[\]!>.#~+]'))) return true;
  for (final p in const ['class.', 'tag.', 'id.', 'text.', 'ownText.', 'children']) {
    if (t.startsWith(p)) return true;
  }
  return false;
}

/// HTML 规则解析（对齐 `AnalyzeByJSoup.kt`）。
class HtmlRule {
  HtmlRule(Object content, {String? baseUrl}) : baseUrl = baseUrl ?? '' {
    if (content is dom.Element) {
      root = content;
    } else if (content is dom.Document) {
      root = content;
    } else {
      root = parseHtmlDocument(content.toString());
    }
  }

  /// 当前解析对象（Document 或 Element）。
  final String baseUrl;
  late final dom.Node root;

  /// 等价 `getStringList`：返回所有匹配的文本/属性值。
  List<String> getStringList(String ruleStr) {
    if (ruleStr.isEmpty) return <String>[];
    final out = <String>[];

    final source = _HtmlSourceRule(ruleStr);
    if (source.elementsRule.isEmpty) {
      out.add(jsoupText(root));
      return out;
    }

    final split = splitCombinator(source.elementsRule, const ['&&', '||', '%%']);
    final results = <List<String>>[];
    for (final part in split.parts) {
      final temp = source.isCss
          ? _resultOfCss(part)
          : _resultOfDefault(part);
      if (temp != null && temp.isNotEmpty) {
        results.add(temp);
        if (split.type == '||') break;
      }
    }
    out.addAll(_mergeStrings(split.type, results));
    return out;
  }

  /// 等价 `getString`：多段用换行连接，空结果返回 null。
  String? getString(String ruleStr) {
    if (ruleStr.isEmpty) return null;
    final list = getStringList(ruleStr);
    if (list.isEmpty) return null;
    if (list.length == 1) return list.first;
    return list.join('\n');
  }

  /// 等价 `getString0`：空结果返回空串。
  String getString0(String ruleStr) {
    final list = getStringList(ruleStr);
    return list.isEmpty ? '' : list.first;
  }

  /// 等价 `getElements`：返回元素列表（供 `getElements` 类规则使用）。
  List<dom.Element> getElements(String ruleStr) {
    if (ruleStr.trim().isEmpty) return <dom.Element>[];
    final source = _HtmlSourceRule(ruleStr);
    final split = splitCombinator(source.elementsRule, const ['&&', '||', '%%']);
    final lists = <List<dom.Element>>[];
    for (final part in split.parts) {
      var elements = <dom.Element>[];
      if (source.isCss) {
        final at = _lastTopLevelAt(part);
        final selector = at < 0 ? part : part.substring(0, at);
        elements = selectElements(root, selector);
      } else {
        final rs = splitTopLevel(trimRulePrefix(part), '@');
        if (rs.length > 1) {
          var current = <dom.Element>[_rootElement];
          for (final rl in rs) {
            final next = <dom.Element>[];
            for (final et in current) {
              next.addAll(_elementsSingle(et, rl));
            }
            current = next;
          }
          elements = current;
        } else {
          for (final et in <dom.Element>[_rootElement]) {
            elements = _elementsSingle(et, part);
          }
        }
      }
      lists.add(elements);
      if (elements.isNotEmpty && split.type == '||') break;
    }
    return _mergeElements(split.type, lists);
  }

  dom.Element get _rootElement {
    final r = root;
    if (r is dom.Element) return r;
    return r.nodes.whereType<dom.Element>().firstOrNull ??
        (dom.Element.tag('html'));
  }

  /// `@CSS:` 分支：拆分选择器与取值关键字（以最后一个 `@` 为界）。
  List<String>? _resultOfCss(String part) {
    final at = _lastTopLevelAt(part);
    final selector = at < 0 ? part : part.substring(0, at);
    final last = at < 0 ? 'text' : part.substring(at + 1);
    final elements = selectElements(root, selector);
    return _resultLast(elements, last);
  }

  List<String>? _resultOfDefault(String ruleStr) {
    if (ruleStr.isEmpty) return null;
    final parts = splitTopLevel(trimRulePrefix(ruleStr), '@');
    if (parts.isEmpty) return null;
    if (parts.length == 1) {
      final seg = parts[0].trim();
      // 单段规则：取值关键字/属性名直接作用于当前元素；选择器先选再取文本
      if (_valueKeywords.contains(seg) || !isSelectorRule(seg)) {
        return _resultLast(<dom.Element>[_rootElement], seg);
      }
      final selected = <dom.Element>[];
      for (final et in <dom.Element>[_rootElement]) {
        selected.addAll(_elementsSingle(et, seg));
      }
      return _resultLast(selected, 'text');
    }
    var elements = <dom.Element>[_rootElement];
    for (var i = 0; i < parts.length - 1; i++) {
      final next = <dom.Element>[];
      for (final et in elements) {
        next.addAll(_elementsSingle(et, parts[i]));
      }
      elements = next;
      if (elements.isEmpty) return null;
    }
    return _resultLast(elements, parts[parts.length - 1]);
  }

  List<String>? _resultLast(List<dom.Element> elements, String lastRule) {
    final keyword = lastRule.trim();
    final out = <String>[];
    switch (keyword) {
      case 'text':
        for (final e in elements) {
          final t = jsoupText(e);
          if (t.isNotEmpty) out.add(t);
        }
      case 'textNodes':
        for (final e in elements) {
          final nodes = jsoupTextNodes(e);
          if (nodes.isNotEmpty) out.add(nodes.join('\n'));
        }
      case 'ownText':
        for (final e in elements) {
          final t = jsoupOwnText(e);
          if (t.isNotEmpty) out.add(t);
        }
      case 'html':
        final sb = StringBuffer();
        for (final e in elements) {
          sb.write(_outerHtmlWithoutScripts(e));
        }
        if (sb.isNotEmpty) out.add(sb.toString());
      case 'all':
        final sb = StringBuffer();
        for (final e in elements) {
          sb.write(e.outerHtml);
        }
        out.add(sb.toString());
      default:
        final abs = keyword.toLowerCase().startsWith('abs:');
        final name = abs ? keyword.substring(4) : keyword;
        for (final e in elements) {
          var value = attrOf(e, name);
          if (abs) value = getAbsoluteUrl(baseUrl, value);
          if (value.trim().isEmpty) continue;
          if (out.contains(value)) continue;
          out.add(value);
        }
    }
    return out;
  }

  String _outerHtmlWithoutScripts(dom.Element element) {
    final clone = element.clone(true);
    for (final tag in const ['script', 'style']) {
      final nodes = clone.querySelectorAll(tag).toList();
      for (final n in nodes) {
        n.remove();
      }
    }
    return clone.outerHtml;
  }

  /// 单段规则：先解析索引，再取基础元素集，最后按索引筛选。
  List<dom.Element> _elementsSingle(dom.Element temp, String rule) {
    final spec = _IndexSpec.parse(rule);
    final elements = _baseElements(temp, spec.beforeRule);
    if (spec.split == ' ' ||
        (spec.indexes.isEmpty && spec.indexDefault.isEmpty)) {
      return elements;
    }
    final n = elements.length;
    if (n == 0) return elements;
    final ordered = <int>[];
    final seen = <int>{};

    void add(int i) {
      if (i >= 0 && i < n && seen.add(i)) ordered.add(i);
    }

    if (spec.indexes.isNotEmpty) {
      for (final item in spec.indexes) {
        if (!item.isRange) {
          final v = item.single!;
          if (v >= 0 && v < n) {
            add(v);
          } else if (v < 0 && n >= -v) {
            add(v + n);
          }
          continue;
        }
        var start = item.start ?? 0;
        if (start < 0) start += n;
        var end = item.end ?? (n - 1);
        if (end < 0) end += n;
        if ((start < 0 && end < 0) || (start >= n && end >= n)) continue;
        if (start >= n) {
          start = n - 1;
        } else if (start < 0) {
          start = 0;
        }
        if (end >= n) {
          end = n - 1;
        } else if (end < 0) {
          end = 0;
        }
        var step = item.step ?? 1;
        if (step == 0) step = 1;
        if (start == end || step >= n) {
          add(start);
          continue;
        }
        if (step < 0 && -step < n) step += n;
        if (step <= 0) step = 1;
        if (end > start) {
          for (var i = start; i <= end; i += step) {
            add(i);
          }
        } else {
          for (var i = start; i >= end; i -= step) {
            add(i);
          }
        }
      }
    } else {
      for (final v in spec.indexDefault) {
        if (v >= 0 && v < n) {
          add(v);
        } else if (v < 0 && n >= -v) {
          add(v + n);
        }
      }
    }

    if (spec.split == '!') {
      return [
        for (var i = 0; i < n; i++)
          if (!seen.contains(i)) elements[i],
      ];
    }
    return [for (final i in ordered) elements[i]];
  }

  List<dom.Element> _baseElements(dom.Element temp, String beforeRule) {
    if (beforeRule.trim().isEmpty) return temp.children;
    final rule = beforeRule.trim();
    final dot = rule.indexOf('.');
    if (dot > 0) {
      final head = rule.substring(0, dot);
      final tail = rule.substring(dot + 1);
      switch (head) {
        case 'children':
          return temp.children;
        case 'class':
          return _descendants(temp)
              .where((e) => e.className.split(RegExp(r'\s+')).contains(tail))
              .toList();
        case 'tag':
          final tag = tail.toLowerCase();
          return _descendants(temp)
              .where((e) => (e.localName ?? '').toLowerCase() == tag)
              .toList();
        case 'id':
          return _descendants(temp).where((e) => e.id == tail).toList();
        case 'text':
          return _descendants(temp)
              .where((e) => jsoupOwnText(e).contains(tail))
              .toList();
        case 'ownText':
          return _descendants(temp)
              .where((e) => jsoupOwnText(e).contains(tail))
              .toList();
      }
    }
    if (rule == 'children') return temp.children;
    return selectElements(temp, rule);
  }

  List<dom.Element> _descendants(dom.Element e) {
    final out = <dom.Element>[];
    void walk(dom.Node node) {
      for (final child in node.nodes) {
        if (child is dom.Element) {
          out.add(child);
          walk(child);
        }
      }
    }

    walk(e);
    return out;
  }
}

/// `@CSS:` 前缀解析（对齐 `AnalyzeByJSoup.SourceRule`）。
class _HtmlSourceRule {
  _HtmlSourceRule(String ruleStr)
      : isCss = ruleStr.length >= 5 &&
            ruleStr.substring(0, 5).toLowerCase() == '@css:',
        elementsRule = ruleStr.length >= 5 &&
                ruleStr.substring(0, 5).toLowerCase() == '@css:'
            ? ruleStr.substring(5).trim()
            : ruleStr;

  final bool isCss;
  final String elementsRule;
}

List<String> _mergeStrings(String type, List<List<String>> results) {
  if (results.isEmpty) return <String>[];
  if (type == '%%') {
    final out = <String>[];
    for (var i = 0; i < results[0].length; i++) {
      for (final r in results) {
        if (i < r.length) out.add(r[i]);
      }
    }
    return out;
  }
  return [for (final r in results) ...r];
}

List<dom.Element> _mergeElements(String type, List<List<dom.Element>> lists) {
  if (lists.isEmpty) return <dom.Element>[];
  if (type == '%%') {
    final out = <dom.Element>[];
    for (var i = 0; i < lists[0].length; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }
  return [for (final l in lists) ...l];
}

int _lastTopLevelAt(String s) {
  final parts = splitTopLevel(s, '@');
  if (parts.length <= 1) return -1;
  // 最后一段之前的长度即分隔位置
  var pos = -1;
  for (var i = 0; i < parts.length - 1; i++) {
    pos = (pos < 0 ? 0 : pos + 1) + parts[i].length;
  }
  return pos;
}

// —— 索引语法 ——

class _IndexItem {
  _IndexItem.single(int value)
      : isRange = false,
        start = null,
        end = null,
        step = null,
        single = value;

  _IndexItem.range(this.start, this.end, this.step)
      : isRange = true,
        single = null;

  final bool isRange;
  final int? single;
  final int? start;
  final int? end;
  final int? step;
}

class _IndexSpec {
  _IndexSpec(this.split, this.beforeRule, this.indexDefault, this.indexes);

  final String split; // '.' 选择 / '!' 排除 / ' ' 不筛选
  final String beforeRule;
  final List<int> indexDefault;
  final List<_IndexItem> indexes;

  /// 解析规则尾部的索引写法。
  ///
  /// 支持 `[0]` `[-1]` `[0:3]` `[1,3]` `[-1:0]` `[3:-2:-10]` `[!0,1]`
  /// 与旧写法 `tag.div.0` / `tag.div!0:1` / `tag.div.-1:10:2`。
  static _IndexSpec parse(String rule) {
    final rus = rule.trim();
    if (rus.isEmpty) return _IndexSpec(' ', rule, const [], const []);

    if (rus.endsWith(']')) {
      final body = rus.substring(0, rus.length - 1);
      final open = _lastOpenBracket(body);
      if (open >= 0) {
        var inner = body.substring(open + 1).trim();
        var negate = false;
        if (inner.startsWith('!')) {
          negate = true;
          inner = inner.substring(1).trim();
        }
        final items = _parseItems(inner);
        if (items != null && items.isNotEmpty) {
          return _IndexSpec(
            negate ? '!' : '.',
            body.substring(0, open),
            const [],
            items,
          );
        }
      }
      return _IndexSpec(' ', rus, const [], const []);
    }

    // 旧写法：从右往左扫描
    final indexDefault = <int>[];
    var l = '';
    var minus = false;
    var i = rus.length - 1;
    while (i >= 0) {
      final c = rus[i];
      if (c == ' ') {
        i--;
        continue;
      }
      if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
        l = '$c$l';
        i--;
        continue;
      }
      if (c == '-') {
        minus = true;
        i--;
        continue;
      }
      if (c == '!' || c == '.' || c == ':') {
        if (l.isEmpty) break;
        final n = int.tryParse(l);
        if (n == null) break;
        indexDefault.add(minus ? -n : n);
        if (c != ':') {
          return _IndexSpec(
            c,
            rus.substring(0, i),
            indexDefault.reversed.toList(),
            const [],
          );
        }
      } else {
        break;
      }
      l = '';
      minus = false;
      i--;
    }
    return _IndexSpec(' ', rus, const [], const []);
  }

  static int _lastOpenBracket(String body) {
    var depth = 0;
    for (var i = body.length - 1; i >= 0; i--) {
      final c = body[i];
      if (c == ']') {
        depth++;
      } else if (c == '[') {
        if (depth == 0) return i;
        depth--;
      }
    }
    return -1;
  }

  static List<_IndexItem>? _parseItems(String inner) {
    if (inner.isEmpty) return null;
    final parts = splitTopLevel(inner, ',');
    final out = <_IndexItem>[];
    for (final raw in parts) {
      final p = raw.trim();
      if (p.isEmpty) return null;
      if (p.contains(':')) {
        final segs = p.split(':');
        if (segs.length > 3) return null;
        final start = segs[0].trim().isEmpty ? null : int.tryParse(segs[0].trim());
        final end = segs[1].trim().isEmpty ? null : int.tryParse(segs[1].trim());
        int? step;
        if (segs.length == 3) {
          step = segs[2].trim().isEmpty ? null : int.tryParse(segs[2].trim());
          if (step == null && segs[2].trim().isNotEmpty) return null;
        }
        if ((segs[0].trim().isNotEmpty && start == null) ||
            (segs[1].trim().isNotEmpty && end == null)) {
          return null;
        }
        out.add(_IndexItem.range(start, end, step));
      } else {
        final v = int.tryParse(p);
        if (v == null) return null;
        out.add(_IndexItem.single(v));
      }
    }
    return out;
  }
}

// —— 选择器引擎 ——

/// 在 [root] 的后代中按 CSS 选择器（jsoup 扩展）选取元素，按文档顺序返回。
List<dom.Element> selectElements(dom.Node root, String selector) {
  final trimmed = selector.trim();
  if (trimmed.isEmpty) return <dom.Element>[];
  final order = _buildOrder(root);
  final groups = splitTopLevel(trimmed, ',');
  final out = <dom.Element>[];
  final seen = <dom.Element>{};
  for (final group in groups) {
    if (group.trim().isEmpty) continue;
    for (final e in _selectComplex(root, group.trim())) {
      if (seen.add(e)) out.add(e);
    }
  }
  out.sort((a, b) => (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30));
  return out;
}

Map<dom.Node, int> _buildOrder(dom.Node root) {
  final map = <dom.Node, int>{};
  var i = 0;
  void walk(dom.Node n) {
    map[n] = i++;
    for (final c in n.nodes) {
      walk(c);
    }
  }

  walk(root);
  return map;
}

class _Compound {
  _Compound(this.tag, this.simples);
  final String? tag; // null 表示 *
  final List<_Simple> simples;
}

sealed class _Simple {}

class _IdSimple extends _Simple {
  _IdSimple(this.id);
  final String id;
}

class _ClassSimple extends _Simple {
  _ClassSimple(this.name);
  final String name;
}

class _AttrSimple extends _Simple {
  _AttrSimple(this.name, this.op, this.value);
  final String name;
  final String? op;
  final String? value;
}

class _PseudoSimple extends _Simple {
  _PseudoSimple(this.name, this.arg);
  final String name;
  final String? arg;
}

/// 把复杂选择器拆成 [(combinator, compound)] 序列。
/// 第一个元素的 combinator 固定为空串。
List<(String, _Compound)> _parseComplex(String group) {
  final out = <(String, _Compound)>[];
  var i = 0;
  var combinator = '';
  final n = group.length;
  while (i < n) {
    // 跳过组合符
    while (i < n && group[i].trim().isEmpty) {
      i++;
      if (out.isNotEmpty && combinator.isEmpty) combinator = ' ';
    }
    if (i >= n) break;
    final c = group[i];
    if (c == '>' || c == '+' || c == '~') {
      combinator = c;
      i++;
      continue;
    }
    final start = i;
    var depth = 0;
    var inSingle = false;
    var inDouble = false;
    while (i < n) {
      final ch = group[i];
      if (ch == '\\') {
        i += 2;
        continue;
      }
      if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (ch == '[' || ch == '(') depth++;
        if (ch == ']' || ch == ')') depth--;
        if (depth == 0 && (ch.trim().isEmpty || ch == '>' || ch == '+' || ch == '~')) {
          break;
        }
      }
      i++;
    }
    final text = group.substring(start, i);
    if (text.isNotEmpty) {
      out.add((out.isEmpty ? '' : (combinator.isEmpty ? ' ' : combinator), _parseCompound(text)));
    }
    combinator = '';
  }
  return out;
}

_Compound _parseCompound(String text) {
  var i = 0;
  String? tag;
  final simples = <_Simple>[];
  final n = text.length;
  // 标签或 *
  final tagMatch = RegExp(r'^(\*|[A-Za-z_][-\w]*)').firstMatch(text);
  if (tagMatch != null) {
    final t = tagMatch.group(1)!;
    tag = t == '*' ? null : t.toLowerCase();
    i = tagMatch.end;
  }
  while (i < n) {
    final c = text[i];
    if (c == '#') {
      final m = RegExp(r'[-\w]+').matchAsPrefix(text, i + 1);
      if (m == null) break;
      simples.add(_IdSimple(m.group(0)!));
      i = m.end;
    } else if (c == '.') {
      final m = RegExp(r'[-\w]+').matchAsPrefix(text, i + 1);
      if (m == null) break;
      simples.add(_ClassSimple(m.group(0)!));
      i = m.end;
    } else if (c == '[') {
      final end = _matchBracket(text, i);
      if (end < 0) break;
      final inner = text.substring(i + 1, end);
      final attr = _parseAttr(inner);
      if (attr != null) simples.add(attr);
      i = end + 1;
    } else if (c == ':') {
      var j = i + 1;
      if (j < n && text[j] == ':') j++;
      final m = RegExp(r'[-\w]+').matchAsPrefix(text, j);
      if (m == null) break;
      final name = m.group(0)!.toLowerCase();
      j = m.end;
      String? arg;
      if (j < n && text[j] == '(') {
        final end = _matchParen(text, j);
        if (end < 0) break;
        arg = text.substring(j + 1, end);
        j = end + 1;
      }
      simples.add(_PseudoSimple(name, arg));
      i = j;
    } else {
      i++;
    }
  }
  return _Compound(tag, simples);
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

int _matchParen(String s, int open) {
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
      if (c == '(') depth++;
      if (c == ')') {
        depth--;
        if (depth == 0) return i;
      }
    }
  }
  return -1;
}

_AttrSimple? _parseAttr(String inner) {
  final m = RegExp(r'^\s*([-\w:]+)\s*(?:([!^$*~|]?=)\s*([\s\S]*))?$').firstMatch(inner);
  if (m == null) return null;
  final name = m.group(1)!;
  final op = m.group(2);
  var value = m.group(3)?.trim();
  if (value != null &&
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'")))) {
    value = value.substring(1, value.length - 1);
  }
  return _AttrSimple(name, op, value);
}

List<dom.Element> _selectComplex(dom.Node root, String group) {
  final steps = _parseComplex(group);
  if (steps.isEmpty) return <dom.Element>[];
  var current = <dom.Element>[_asElement(root)];
  var first = true;
  for (final (combinator, compound) in steps) {
    final candidates = <dom.Element>[];
    if (first) {
      for (final e in _allDescendants(root)) {
        candidates.add(e);
      }
      first = false;
    } else {
      switch (combinator) {
        case '>':
          for (final e in current) {
            candidates.addAll(e.children);
          }
        case '+':
          for (final e in current) {
            final next = e.nextElementSibling;
            if (next != null) candidates.add(next);
          }
        case '~':
          for (final e in current) {
            var sib = e.nextElementSibling;
            while (sib != null) {
              candidates.add(sib);
              sib = sib.nextElementSibling;
            }
          }
        default:
          for (final e in current) {
            candidates.addAll(_allDescendants(e));
          }
      }
    }
    final matched = <dom.Element>[];
    for (final c in candidates) {
      if (_matchesCompound(c, compound)) matched.add(c);
    }
    current = matched;
    if (current.isEmpty) break;
  }
  return current;
}

dom.Element _asElement(dom.Node node) {
  if (node is dom.Element) return node;
  return node.nodes.whereType<dom.Element>().firstOrNull ?? dom.Element.tag('html');
}

List<dom.Element> _allDescendants(dom.Node root) {
  final out = <dom.Element>[];
  void walk(dom.Node node) {
    for (final c in node.nodes) {
      if (c is dom.Element) {
        out.add(c);
        walk(c);
      }
    }
  }

  walk(root);
  return out;
}

bool _matchesCompound(dom.Element element, _Compound compound) {
  if (compound.tag != null && compound.tag != '*') {
    if ((element.localName ?? '').toLowerCase() != compound.tag) return false;
  }
  for (final simple in compound.simples) {
    if (!_matchesSimple(element, simple)) return false;
  }
  return true;
}

bool _matchesSimple(dom.Element element, _Simple simple) {
  switch (simple) {
    case _IdSimple(:final id):
      return element.id == id;
    case _ClassSimple(:final name):
      return element.className
          .split(RegExp(r'\s+'))
          .any((c) => c == name);
    case _AttrSimple(:final name, :final op, :final value):
      final actual = attrOf(element, name);
      if (op == null) return hasAttr(element, name);
      if (op == '!=') return actual != value;
      if (!hasAttr(element, name)) return false;
      final v = value ?? '';
      switch (op) {
        case '=':
          return actual == v;
        case '^=':
          return actual.startsWith(v);
        case r'$=':
          return actual.endsWith(v);
        case '*=':
          return actual.contains(v);
        case '~=':
          return actual.split(RegExp(r'\s+')).any((s) => s == v);
        case '|=':
          return actual == v || actual.startsWith('$v-');
      }
      return false;
    case _PseudoSimple(:final name, :final arg):
      return _matchesPseudo(element, name, arg);
  }
}

int _siblingIndex(dom.Element e) {
  final parent = e.parentNode;
  if (parent == null) return 0;
  var i = 0;
  for (final n in parent.nodes) {
    if (n is dom.Element) {
      if (identical(n, e)) return i;
      i++;
    }
  }
  return i;
}

int _siblingCount(dom.Element e) {
  final parent = e.parentNode;
  if (parent == null) return 1;
  return parent.nodes.whereType<dom.Element>().length;
}

bool _matchesPseudo(dom.Element element, String name, String? arg) {
  switch (name) {
    case 'first-child':
      return _siblingIndex(element) == 0;
    case 'last-child':
      return _siblingIndex(element) == _siblingCount(element) - 1;
    case 'only-child':
      return _siblingCount(element) == 1;
    case 'nth-child':
      final n = int.tryParse((arg ?? '').trim());
      if (n == null || n <= 0) return false;
      return _siblingIndex(element) == n - 1;
    case 'first':
      return _siblingIndex(element) == 0;
    case 'last':
      return _siblingIndex(element) == _siblingCount(element) - 1;
    case 'eq':
      final n = int.tryParse((arg ?? '').trim());
      if (n == null) return false;
      final idx = _siblingIndex(element);
      return n >= 0 ? idx == n : idx == _siblingCount(element) + n;
    case 'lt':
      final n = int.tryParse((arg ?? '').trim());
      if (n == null) return false;
      final idx = _siblingIndex(element);
      return n >= 0 ? idx < n : idx < _siblingCount(element) + n;
    case 'gt':
      final n = int.tryParse((arg ?? '').trim());
      if (n == null) return false;
      final idx = _siblingIndex(element);
      return n >= 0 ? idx > n : idx > _siblingCount(element) + n;
    case 'even':
      return _siblingIndex(element) % 2 == 0;
    case 'odd':
      return _siblingIndex(element) % 2 == 1;
    case 'contains':
      return jsoupText(element).toLowerCase().contains((arg ?? '').toLowerCase());
    case 'containsown':
      return jsoupOwnText(element)
          .toLowerCase()
          .contains((arg ?? '').toLowerCase());
    case 'matches':
      try {
        return RegExp(arg ?? '').hasMatch(jsoupText(element));
      } catch (_) {
        return false;
      }
    case 'has':
      return selectElements(element, arg ?? '').isNotEmpty;
    case 'not':
      for (final g in splitTopLevel(arg ?? '', ',')) {
        if (g.trim().isEmpty) continue;
        if (_matchesSelectorText(element, g.trim())) return false;
      }
      return true;
    case 'empty':
      return element.nodes.every(
        (n) => n is! dom.Element && (n is! dom.Text || n.text.trim().isEmpty),
      );
    case 'root':
      return element.parentNode is dom.Document;
    case 'header':
    case 'input':
    case 'button':
      return false;
  }
  return false;
}

bool _matchesSelectorText(dom.Element element, String selector) {
  final compound = _parseCompound(selector.trim());
  return _matchesCompound(element, compound);
}
