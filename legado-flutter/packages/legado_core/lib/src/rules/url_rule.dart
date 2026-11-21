/// URL 规则解析（对齐 `AnalyzeUrl.kt`）。
///
/// 一条 URL 规则形如：
/// ```
/// https://x.com/search?q={{key}}&p={{page}},{"method":"POST","headers":{...},"charset":"gbk"}
/// ```
/// 处理顺序（不能调换）：
/// 1. `<js>` / `@js:` 求值（`@result` 可引用上一段结果）；
/// 2. `{{...}}` 求值（`key`/`page` 是内置变量）；
/// 3. `<1,2,3>` 分页占位；
/// 4. 切出 `,{...}` 选项 → 相对地址绝对化 → 查询串编码。
library;

import 'dart:convert';

import '../net/charset.dart' as charset_utils;
import '../util/url.dart';
import 'rule.dart';
import 'rule_splitter.dart';
import 'source_rules.dart';

/// 解析后的 URL 及其请求参数。
class AnalyzedUrl {
  const AnalyzedUrl({
    required this.ruleUrl,
    required this.url,
    required this.urlNoQuery,
    required this.baseUrl,
    this.encodedQuery,
    this.encodedForm,
    this.method = 'GET',
    this.body,
    this.headers = const {},
    this.charset,
    this.type,
    this.retry = 0,
    this.useWebView = false,
    this.webJs,
    this.serverId,
    this.webViewDelayTime = 0,
    this.option,
  });

  /// 规则原串（先展开 JS/`{{}}`/分页，未绝对化）。
  final String ruleUrl;

  /// 最终 URL（GET 时 query 已编码）。
  final String url;

  /// 不含 query 的部分（POST 请求用它）。
  final String urlNoQuery;

  /// 以当前 URL 重新计算出的 baseUrl。
  final String baseUrl;

  final String? encodedQuery;
  final String? encodedForm;
  final String method;
  final String? body;
  final Map<String, String> headers;
  final String? charset;

  /// 非空表示响应体要按 hex 处理（音频/图片源）。
  final String? type;
  final int retry;
  final bool useWebView;
  final String? webJs;
  final int? serverId;
  final int webViewDelayTime;
  final UrlOption? option;

  bool get isPost => method.toUpperCase() == 'POST';
}

/// URL 规则解析器。
///
/// 与 [AnalyzeRule] 分开：URL 规则不需要「内容」，但需要 `key`/`page` 绑定。
class UrlRuleAnalyzer {
  UrlRuleAnalyzer(this.context, {this.key, this.page});

  final RuleContext context;
  final String? key;
  final int? page;

  static final _jsPattern =
      RegExp(r'<js>([\s\S]*?)</js>|@js:([\s\S]*)', caseSensitive: false);
  static final _pagePattern = RegExp(r'<(.*?)>');
  static final _paramPattern = RegExp(r'\s*,\s*(?=\{)');

  /// 解析一条 URL 规则。
  Future<AnalyzedUrl> analyze(String ruleUrl, {String baseUrl = ''}) async {
    var currentBase = baseUrl;
    var rule = await _analyzeJs(ruleUrl);
    rule = await _replaceKeyPageJs(rule);

    final urlNoOption = _splitUrlOption(rule);
    var url = getAbsoluteUrl(currentBase, urlNoOption.url);
    currentBase = getBaseUrl(url) ?? currentBase;

    UrlOption? option;
    final optionStr = urlNoOption.option;
    if (optionStr != null) {
      option = _parseOption(optionStr);
    }

    var method = 'GET';
    final headers = <String, String>{};
    String? body;
    String? charset;
    String? type;
    var retry = 0;
    var useWebView = false;
    String? webJs;

    if (option != null) {
      if ((option.method ?? '').toUpperCase() == 'POST') method = 'POST';
      final h = option.headers;
      if (h is Map) {
        h.forEach((k, v) => headers[k.toString()] = v?.toString() ?? '');
      }
      if (option.body != null) body = _bodyToString(option.body);
      type = option.type;
      charset = option.charset;
      retry = option.retry ?? 0;
      useWebView = option.useWebView;
      webJs = option.webJs;
      final jsStr = option.js;
      if (jsStr != null && jsStr.isNotEmpty) {
        final v = await _evalJs(jsStr, url);
        if (v != null) url = v.toString();
      }
    }

    var urlNoQuery = url;
    String? encodedQuery;
    String? encodedForm;
    if (method == 'GET') {
      final pos = url.indexOf('?');
      if (pos >= 0) {
        final query = url.substring(pos + 1);
        encodedQuery = encodeQuery(query, charset);
        url = '${url.substring(0, pos)}?$encodedQuery';
        urlNoQuery = url.substring(0, pos);
      }
    } else if (body != null &&
        !isJsonLikeBody(body) &&
        !_isXmlLike(body) &&
        (headers['Content-Type'] ?? headers['content-type'] ?? '').isEmpty) {
      encodedForm = encodeForm(body, charset);
    }

    return AnalyzedUrl(
      ruleUrl: rule,
      url: url,
      urlNoQuery: urlNoQuery,
      baseUrl: currentBase,
      encodedQuery: encodedQuery,
      encodedForm: encodedForm,
      method: method,
      body: body,
      headers: headers,
      charset: charset,
      type: type,
      retry: retry,
      useWebView: useWebView,
      webJs: webJs,
      serverId: option?.serverID,
      webViewDelayTime: option?.webViewDelayTime ?? 0,
      option: option,
    );
  }

  /// 执行 `<js>` / `@js:`，段外文本里的 `@result` 会被替换成已计算结果。
  Future<String> _analyzeJs(String ruleUrl) async {
    var result = ruleUrl;
    var start = 0;
    for (final m in _jsPattern.allMatches(ruleUrl)) {
      if (m.start > start) {
        final seg = ruleUrl.substring(start, m.start).trim();
        if (seg.isNotEmpty) result = seg.replaceAll('@result', result);
      }
      final code = m.group(2) ?? m.group(1) ?? '';
      final v = await _evalJs(code, result);
      result = v?.toString() ?? '';
      start = m.end;
    }
    if (ruleUrl.length > start) {
      final seg = ruleUrl.substring(start).trim();
      if (seg.isNotEmpty) result = seg.replaceAll('@result', result);
    }
    return result;
  }

  /// 替换 `{{key}}` / `{{page}}` / 任意 JS 表达式，以及 `<1,2,3>` 分页。
  Future<String> _replaceKeyPageJs(String ruleUrl) async {
    var rule = ruleUrl;
    if (rule.contains('{{') && rule.contains('}}')) {
      final replaced = await replaceDoubleBrace(
        rule,
        (inner) async {
          final v = await _evalJs(inner, null);
          return v?.toString() ?? '';
        },
      );
      // 与 Kotlin 一致：替换结果非空才覆盖（表达式求值为空串是有效结果）
      if (replaced.replaced && replaced.value.isNotEmpty) {
        rule = replaced.value;
      }
    }
    final p = page;
    if (p != null) {
      while (true) {
        final m = _pagePattern.firstMatch(rule);
        if (m == null) break;
        final pages = m.group(1)!.split(',');
        final value = p >= 1 && p <= pages.length
            ? pages[p - 1].trim()
            : pages.last.trim();
        rule = rule.replaceRange(m.start, m.end, value);
      }
    }
    return rule;
  }

  ({String url, String? option}) _splitUrlOption(String rule) {
    final m = _paramPattern.firstMatch(rule);
    if (m == null) return (url: rule, option: null);
    return (url: rule.substring(0, m.start), option: rule.substring(m.end));
  }

  UrlOption? _parseOption(String optionStr) {
    final text = optionStr.trim();
    final fixed = lenientJson(text.replaceAllMapped(RegExp(r',\s*([\]}])'), (m) => m[1]!));
    try {
      final decoded = jsonDecode(fixed);
      if (decoded is Map) {
        return UrlOption.fromJson(Map<String, Object?>.from(decoded));
      }
    } catch (_) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          return UrlOption.fromJson(Map<String, Object?>.from(decoded));
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String _bodyToString(Object? body) {
    if (body is String) return body;
    return jsonEncode(body);
  }

  Future<Object?> _evalJs(String script, Object? result) {
    return context.js.eval(script, bindings: <String, Object?>{
      'result': result,
      'baseUrl': context.baseUrl,
      'key': key,
      'page': page,
      'source': context.source,
      'java': context.javaHost,
      ...context.variables,
    });
  }
}


/// body 是否长得像 JSON（对象或数组）。
///
/// 用于决定 POST 时该按 JSON 还是表单发送。
bool isJsonLikeBody(String s) {
  final t = s.trim();
  if (!t.startsWith('{') && !t.startsWith('[')) return false;
  try {
    jsonDecode(t);
    return true;
  } catch (_) {
    return false;
  }
}

bool _isXmlLike(String s) => s.trim().startsWith('<');

/// 查询串编码：保留 URL 合法字符与已有的 `%XX`，其余按 [charset] 百分号编码。
///
/// **必须按 `charset` 取字节**：GBK 站点的搜索参数若按 UTF-8 编码
/// （`%E4%B8%AD`），服务端会当 GBK 解成乱码，表现为「HTTP 200 + 0 条结果」。
String encodeQuery(String query, String? charset) {
  if (_looksEncoded(query)) return query;
  return query.split('&').map((pair) {
    final eq = pair.indexOf('=');
    if (eq < 0) {
      return _percentEncode(pair, form: false, charset: charset);
    }
    return '${_percentEncode(pair.substring(0, eq), form: false, charset: charset)}'
        '=${_percentEncode(pair.substring(eq + 1), form: false, charset: charset)}';
  }).join('&');
}

/// 表单编码（POST `application/x-www-form-urlencoded`）：空格用 `+`。
String encodeForm(String form, String? charset) {
  if (charset != null && charset.toLowerCase() == 'escape') {
    return _legacyEscape(form);
  }
  return form.split('&').map((pair) {
    final eq = pair.indexOf('=');
    if (eq < 0) {
      return _percentEncode(pair, form: true, charset: charset);
    }
    return '${_percentEncode(pair.substring(0, eq), form: true, charset: charset)}'
        '=${_percentEncode(pair.substring(eq + 1), form: true, charset: charset)}';
  }).join('&');
}

const _unreserved =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
const _querySafe = r"!$&'()*+,/:;=?@[]^`{|}";

String _percentEncode(String value, {required bool form, String? charset}) {
  final sb = StringBuffer();
  var i = 0;
  while (i < value.length) {
    final cu = value.codeUnitAt(i);
    if (cu < 0x80) {
      final ch = String.fromCharCode(cu);
      if (ch == '%') {
        if (_isPercentEscapeAt(value, i)) {
          sb.write('%');
        } else {
          sb.write('%25');
        }
        i++;
        continue;
      }
      if (ch == ' ' && form) {
        sb.write('+');
        i++;
        continue;
      }
      if (_unreserved.contains(ch) || _querySafe.contains(ch)) {
        sb.write(ch);
        i++;
        continue;
      }
      sb.write('%${cu.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      i++;
      continue;
    }
    final rune = value.substring(i).runes.first;
    final ch = String.fromCharCode(rune);
    // 老字符集站点（GBK/GB2312）要按目标编码取字节，否则中文参数是乱码。
    for (final b in charset_utils.encode(ch, charset: charset)) {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
    i += ch.length;
  }
  return sb.toString();
}

bool _isPercentEscapeAt(String s, int i) {
  if (i + 2 >= s.length) return false;
  final h1 = s.codeUnitAt(i + 1);
  final h2 = s.codeUnitAt(i + 2);
  bool hex(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x46) ||
      (c >= 0x61 && c <= 0x66);
  return hex(h1) && hex(h2);
}

/// 判断整条 query 是否已经是编码过的（含 `%XX` 且无中文/空格）。
bool _looksEncoded(String query) {
  if (query.contains('%')) return _isPercentEscapeAt(query, query.indexOf('%'));
  for (final r in query.runes) {
    if (r > 0x7F) return false;
  }
  return false;
}

/// 旧式 `escape` 编码（GBK 源常用 `charset: "escape"`）。
String _legacyEscape(String value) {
  final sb = StringBuffer();
  for (final ch in value.split('')) {
    final code = ch.codeUnitAt(0);
    if (_unreserved.contains(ch) || ch == '@' || ch == '*' || ch == '-' ||
        ch == '_' || ch == '+' || ch == '.' || ch == '/') {
      sb.write(ch);
    } else if (code < 0x80) {
      sb.write('%${code.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    } else {
      sb.write('%u${code.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    }
  }
  return sb.toString();
}
