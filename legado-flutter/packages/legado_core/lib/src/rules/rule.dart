/// 规则片段解析（对齐 `AnalyzeRule.kt` 的 `SourceRule` / `splitSourceRule`）。
///
/// 一条书源规则串可能包含多种成分：
/// - 模式前缀：`@CSS:` `@@` `@XPath:` `@Json:`，或按内容/写法推断（`$.` / `//`）；
/// - `@put:{...}` 变量写入、`@get:{...}` 变量读取、`{{...}}` JS 求值；
/// - `##regex##replacement` 正则替换（第四段存在时只替换首个匹配）。
///
/// 这些成分的执行顺序会影响结果（先算 `{{}}` 再切 `##`），所以必须按原版顺序处理。
library;

import 'dart:convert';

import '../js/java_host.dart';
import '../js/js_engine.dart';
import 'regex_rule.dart';

/// 规则解析模式。
enum RuleMode {
  /// CSS 选择器（默认）。
  css,

  /// XPath。
  xpath,

  /// JSONPath。
  json,

  /// 内嵌 JS。
  js,

  /// 正则（或「已是纯文本」：`{{}}`/`@get` 求值后的结果）。
  regex,
}

/// 规则层对外部世界的最小依赖。
///
/// 故意不暴露网络/存储：规则解析只该看到「当前页面/JSON、baseUrl、变量、JS 引擎」，
/// 依赖面越小，测试越好写（`SimpleRuleContext` 就能跑全部用例）。
abstract class RuleContext {
  /// 脚本执行器。
  JsEngine get js;

  /// 当前页面的基础地址（相对 URL 绝对化用）。
  String get baseUrl;

  /// 书源/书籍变量表，`@put` 写入、`@get` 读取。
  Map<String, String> get variables;

  /// 当前解析对象（书源实体等），原样透传给 JS 的 `source`。
  Object? get source;

  String getVariable(String key) => variables[key] ?? '';

  void putVariable(String key, String value) => variables[key] = value;

  /// 规则脚本可用的 `java` 宿主对象。
  ///
  /// 书源规则里 `java.encodeURI(...)`、`java.base64Decode(...)` 这类调用是标配，
  /// 缺了会让整条规则直接抛 `ReferenceError`。默认给一个「只含纯计算能力」的
  /// 实例（不联网、不读规则），service 层可以覆盖成带网络能力的版本。
  Object? get javaHost => _defaultJavaHost;

  /// 额外的 JS 全局绑定。
  ///
  /// 对齐原版 `AnalyzeRule.evalJS` 的绑定集合：`book`、`chapter`、`title`、
  /// `src`、`nextChapterUrl` 等。书源规则里 `book.bookUrl` 这类写法很常见，
  /// 少了这些绑定会直接抛 `ReferenceError: "book" 未定义`。
  Map<String, Object?> get extraBindings => const {};

  /// 执行脚本，注入常用绑定。
  Future<Object?> evalJs(String script, Object? result) {
    return js.eval(script, bindings: <String, Object?>{
      'result': result,
      'baseUrl': baseUrl,
      'source': source,
      'java': javaHost,
      ...extraBindings,
      ...variables,
    });
  }
}

/// 默认 `java` 对象：只提供纯计算能力（base64/md5/hex/编码/时间/html 去标签）。
///
/// 需要 `java.ajax` / `java.getString` 这类能力时，由 service 层构造带回调的实例覆盖。
final Object _defaultJavaHost = createJavaObject();

/// 不做任何脚本求值的空引擎：给「只测 CSS/XPath/JSONPath」的场景用。
class NoopJsEngine implements JsEngine {
  const NoopJsEngine();

  @override
  Future<Object?> eval(String script, {Map<String, Object?> bindings = const {}}) async =>
      null;

  @override
  void dispose() {}
}

/// 规则层的默认上下文实现（service 层和测试可以直接用）。
class SimpleRuleContext extends RuleContext {
  SimpleRuleContext({
    JsEngine? js,
    this.baseUrl = '',
    Map<String, String>? variables,
    this.source,
    this.javaHost,
    this.extraBindings = const {},
  })  : js = js ?? const NoopJsEngine(),
        variables = variables ?? <String, String>{};

  @override
  final JsEngine js;

  @override
  final String baseUrl;

  @override
  final Map<String, String> variables;

  @override
  final Object? source;

  @override
  final Object? javaHost;

  @override
  final Map<String, Object?> extraBindings;
}

/// 规则片段中的一个参数（`{{js}}` / `@get:` / `$1` / 普通文本）。
class RuleParam {
  const RuleParam(this.type, this.value);

  /// `>= 0` 表示 `$n` 分组下标；`-1` 表示 JS；`-2` 表示 `@get`；`0` 表示普通文本。
  final int type;
  final String value;
}

const int _jsParam = -1;
const int _getParam = -2;
const int _defaultParam = 0;

/// `makeUpRule` 需要的回调（避免 rule.dart 反向依赖 analyze_rule.dart）。
typedef JsEvalCallback = Future<Object?> Function(String script, Object? result);
typedef RuleStringCallback = Future<String> Function(String rule);

/// 单条规则片段。
class SourceRule {
  SourceRule(
    this.raw, {
    required this.contentIsJson,
    RuleMode? initialMode,
  }) : mode = initialMode ?? RuleMode.css {
    _init();
  }

  final String raw;
  final bool contentIsJson;

  RuleMode mode;

  /// 计算后的规则主体（不含 `@put` / `##regex##`）。
  String rule = '';

  String replaceRegex = '';
  String replacement = '';
  bool replaceFirst = false;

  /// `@put:{...}` 里的键值。
  final Map<String, String> putMap = <String, String>{};

  List<RuleParam> params = <RuleParam>[];

  static final _putPattern =
      RegExp(r'@put:(\{[^}]+?\})', caseSensitive: false);
  static final _evalPattern =
      RegExp(r'@get:\{[^}]+?\}|\{\{[\s\S]*?\}\}', caseSensitive: false);
  static final _groupRefPattern = RegExp(r'\$\d{1,2}');

  void _init() {
    final r = raw;
    if (mode == RuleMode.js || mode == RuleMode.regex) {
      rule = r;
    } else if (_startsWithCi(r, '@css:')) {
      mode = RuleMode.css;
      rule = r;
    } else if (r.startsWith('@@')) {
      mode = RuleMode.css;
      rule = r.substring(2);
    } else if (_startsWithCi(r, '@xpath:')) {
      mode = RuleMode.xpath;
      rule = r.substring(7);
    } else if (_startsWithCi(r, '@json:')) {
      mode = RuleMode.json;
      rule = r.substring(6);
    } else if (contentIsJson || r.startsWith('\$.') || r.startsWith('\$[')) {
      mode = RuleMode.json;
      rule = r;
    } else if (r.startsWith('/')) {
      mode = RuleMode.xpath;
      rule = r;
    } else {
      rule = r;
    }

    rule = _splitPutRule(rule, putMap);

    var start = 0;
    final matches = _evalPattern.allMatches(rule).toList();
    if (matches.isNotEmpty) {
      final first = matches.first;
      final head = rule.substring(0, first.start);
      if (mode != RuleMode.js &&
          mode != RuleMode.regex &&
          (first.start == 0 || !head.contains('##'))) {
        mode = RuleMode.regex;
      }
      for (final m in matches) {
        if (m.start > start) {
          _splitRegex(rule.substring(start, m.start));
        }
        final token = m.group(0)!;
        if (token.toLowerCase().startsWith('@get:')) {
          params.add(RuleParam(_getParam, token.substring(6, token.length - 1)));
        } else {
          params.add(RuleParam(_jsParam, token.substring(2, token.length - 2)));
        }
        start = m.end;
      }
    }
    if (rule.length > start) {
      _splitRegex(rule.substring(start));
    }
  }

  static bool _startsWithCi(String s, String prefix) =>
      s.length >= prefix.length &&
      s.substring(0, prefix.length).toLowerCase() == prefix;

  String _splitPutRule(String input, Map<String, String> sink) {
    var out = input;
    for (final m in _putPattern.allMatches(input)) {
      out = out.replaceFirst(m.group(0)!, '');
      final body = m.group(1)!;
      final map = _parseJsonObject(body);
      if (map != null) sink.addAll(map);
    }
    return out;
  }

  Map<String, String>? _parseJsonObject(String body) {
    var text = body.trim();
    if (!text.startsWith('{')) return null;
    // 宽松处理：单引号、未加引号的键
    text = text.replaceAll("'", '"');
    text = text.replaceAllMapped(
      RegExp(r'([{,]\s*)([A-Za-z_][\w\-]*)\s*:'),
      (m) => '${m[1]}"${m[2]}":',
    );
    try {
      final decoded = _jsonDecode(text);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 拆分 `$1` 分组引用（`##` 之前的片段）。
  void _splitRegex(String segment) {
    var start = 0;
    final headParts = segment.split('##');
    final head = headParts.first;
    final matches = _groupRefPattern.allMatches(head).toList();
    if (matches.isNotEmpty) {
      if (mode != RuleMode.js && mode != RuleMode.regex) {
        mode = RuleMode.regex;
      }
      for (final m in matches) {
        if (m.start > start) {
          params.add(RuleParam(_defaultParam, segment.substring(start, m.start)));
        }
        final token = m.group(0)!;
        params.add(RuleParam(int.parse(token.substring(1)), token));
        start = m.end;
      }
    }
    if (segment.length > start) {
      params.add(RuleParam(_defaultParam, segment.substring(start)));
    }
  }

  /// 是否是一条「规则」（而非 JS 表达式）：`{{}}` 里出现这些前缀时按规则递归求值。
  static bool isRule(String ruleStr) {
    return ruleStr.startsWith('@') ||
        ruleStr.startsWith('\$.') ||
        ruleStr.startsWith('\$[') ||
        ruleStr.startsWith('//');
  }

  int get paramSize => params.length;

  /// 把 `{{}}` / `@get` / `$n` 展开成最终规则串，并拆出 `##regex##replacement`。
  Future<void> makeUpRule(
    Object? result, {
    required JsEvalCallback evalJs,
    required RuleStringCallback getString,
    required String Function(String key) getVar,
  }) async {
    if (params.isNotEmpty) {
      final sb = StringBuffer();
      for (final p in params) {
        if (p.type >= 0) {
          if (result is List && result.length > p.type) {
            final v = result[p.type];
            if (v != null) sb.write(v);
          } else {
            sb.write(p.value);
          }
        } else if (p.type == _jsParam) {
          if (isRule(p.value)) {
            sb.write(await getString(p.value));
          } else {
            final v = await evalJs(p.value, result);
            sb.write(_jsToString(v));
          }
        } else if (p.type == _getParam) {
          sb.write(getVar(p.value));
        } else {
          sb.write(p.value);
        }
      }
      rule = sb.toString();
    }

    final parts = rule.split('##');
    rule = parts.first.trim();
    if (parts.length > 1) replaceRegex = parts[1];
    if (parts.length > 2) replacement = parts[2];
    if (parts.length > 3) replaceFirst = true;
  }
}

/// JS 结果转字符串（对齐 Kotlin 里对 Double 的特殊处理：整数不带 `.0`）。
String _jsToString(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is double && v == v.roundToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  if (v is List) return '[${v.map(_jsToString).join(', ')}]';
  return v.toString();
}

/// 按 `<js>` / `@js:` 切分规则串（对齐 `AnalyzeRule.splitSourceRule`）。
List<SourceRule> splitSourceRule(
  String? ruleStr, {
  bool contentIsJson = false,
  bool allInOne = false,
}) {
  if (ruleStr == null || ruleStr.isEmpty) return <SourceRule>[];
  final out = <SourceRule>[];
  var mode = RuleMode.css;
  var start = 0;
  // 仅首字符为 `:` 时表示整条按正则处理（与伪类选择器冲突，仅为兼容旧规则）
  if (allInOne && ruleStr.startsWith(':')) {
    mode = RuleMode.regex;
    start = 1;
  }
  final jsPattern =
      RegExp(r'<js>([\s\S]*?)</js>|@js:([\s\S]*)', caseSensitive: false);
  for (final m in jsPattern.allMatches(ruleStr)) {
    if (m.start > start) {
      final tmp = ruleStr.substring(start, m.start).trim();
      if (tmp.isNotEmpty) {
        out.add(SourceRule(tmp, contentIsJson: contentIsJson, initialMode: mode));
      }
    }
    final code = m.group(2) ?? m.group(1) ?? '';
    out.add(SourceRule(code, contentIsJson: contentIsJson, initialMode: RuleMode.js));
    start = m.end;
  }
  if (ruleStr.length > start) {
    final tmp = ruleStr.substring(start).trim();
    if (tmp.isNotEmpty) {
      out.add(SourceRule(tmp, contentIsJson: contentIsJson, initialMode: mode));
    }
  }
  return out;
}

/// 对结果执行 `##regex##replacement`。
String applyReplaceRegex(String input, SourceRule rule) {
  if (rule.replaceRegex.isEmpty) return input;
  return regexReplace(
    input,
    rule.replaceRegex,
    rule.replacement,
    replaceFirst: rule.replaceFirst,
  );
}

Object? _jsonDecode(String text) => jsonDecode(text);
