/// 书源规则值对象。
///
/// 为什么规则层不直接用 `lib/src/domain/BookSource`：
/// 内核里 domain 与 rules 是两个并行的模块（并行开发契约），规则层只依赖
/// 「书源 JSON 长什么样」，不依赖实体的存储细节。字段名与书源 JSON 完全一致，
/// service 层负责把 BookSource 转成这里的值对象。
///
/// 空串与 null 的区别照抄 Kotlin：书源里 `""` 常常表示「用默认值」，
/// 而 `null` 表示「没有这条规则」，两者在判断分支上不等价，所以全部字段用 `String?`。
library;

import 'dart:convert';

/// 书源规则块的公共行为：从 JSON 构造、序列化回 JSON。
abstract class JsonRuleBlock {
  const JsonRuleBlock();

  /// 字段名 → 值，序列化时按子类声明的顺序输出。
  Map<String, Object?> toJson();

  /// Gson 默认不输出 null 字段，这里保持一致（导出的书源里看不到未设置项）。
  Map<String, Object?> toJsonWithoutNulls() {
    final out = <String, Object?>{};
    toJson().forEach((k, v) {
      if (v != null) out[k] = v;
    });
    return out;
  }
}

/// 把 JSON 里的任意标量宽松地转成 String。
///
/// 部分书源把 `wordCount` 写成数字、把 `bookList` 写成 `true`，
/// 原版 Gson 会把它们转成 `"123"` / `"true"` 而不报错。
String? jsonString(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  return value.toString();
}

/// 搜索结果规则（`ruleSearch`）。
class SearchRule extends JsonRuleBlock {
  const SearchRule({
    this.checkKeyWord,
    this.bookList,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.bookUrl,
    this.coverUrl,
    this.wordCount,
  });

  factory SearchRule.fromJson(Map<String, Object?> json) => SearchRule(
        checkKeyWord: jsonString(json['checkKeyWord']),
        bookList: jsonString(json['bookList']),
        name: jsonString(json['name']),
        author: jsonString(json['author']),
        intro: jsonString(json['intro']),
        kind: jsonString(json['kind']),
        lastChapter: jsonString(json['lastChapter']),
        updateTime: jsonString(json['updateTime']),
        bookUrl: jsonString(json['bookUrl']),
        coverUrl: jsonString(json['coverUrl']),
        wordCount: jsonString(json['wordCount']),
      );

  final String? checkKeyWord;
  final String? bookList;
  final String? name;
  final String? author;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final String? bookUrl;
  final String? coverUrl;
  final String? wordCount;

  @override
  Map<String, Object?> toJson() => {
        'checkKeyWord': checkKeyWord,
        'bookList': bookList,
        'name': name,
        'author': author,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'updateTime': updateTime,
        'bookUrl': bookUrl,
        'coverUrl': coverUrl,
        'wordCount': wordCount,
      };
}

/// 书籍详情页规则（`ruleBookInfo`）。
class BookInfoRule extends JsonRuleBlock {
  const BookInfoRule({
    this.init,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.coverUrl,
    this.tocUrl,
    this.wordCount,
    this.canReName,
    this.downloadUrls,
  });

  factory BookInfoRule.fromJson(Map<String, Object?> json) => BookInfoRule(
        init: jsonString(json['init']),
        name: jsonString(json['name']),
        author: jsonString(json['author']),
        intro: jsonString(json['intro']),
        kind: jsonString(json['kind']),
        lastChapter: jsonString(json['lastChapter']),
        updateTime: jsonString(json['updateTime']),
        coverUrl: jsonString(json['coverUrl']),
        tocUrl: jsonString(json['tocUrl']),
        wordCount: jsonString(json['wordCount']),
        canReName: jsonString(json['canReName']),
        downloadUrls: jsonString(json['downloadUrls']),
      );

  final String? init;
  final String? name;
  final String? author;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final String? coverUrl;
  final String? tocUrl;
  final String? wordCount;
  final String? canReName;
  final String? downloadUrls;

  @override
  Map<String, Object?> toJson() => {
        'init': init,
        'name': name,
        'author': author,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'updateTime': updateTime,
        'coverUrl': coverUrl,
        'tocUrl': tocUrl,
        'wordCount': wordCount,
        'canReName': canReName,
        'downloadUrls': downloadUrls,
      };
}

/// 目录页规则（`ruleToc`）。
class TocRule extends JsonRuleBlock {
  const TocRule({
    this.preUpdateJs,
    this.chapterList,
    this.chapterName,
    this.chapterUrl,
    this.formatJs,
    this.isVolume,
    this.isVip,
    this.isPay,
    this.updateTime,
    this.nextTocUrl,
  });

  factory TocRule.fromJson(Map<String, Object?> json) => TocRule(
        preUpdateJs: jsonString(json['preUpdateJs']),
        chapterList: jsonString(json['chapterList']),
        chapterName: jsonString(json['chapterName']),
        chapterUrl: jsonString(json['chapterUrl']),
        formatJs: jsonString(json['formatJs']),
        isVolume: jsonString(json['isVolume']),
        isVip: jsonString(json['isVip']),
        isPay: jsonString(json['isPay']),
        updateTime: jsonString(json['updateTime']),
        nextTocUrl: jsonString(json['nextTocUrl']),
      );

  final String? preUpdateJs;
  final String? chapterList;
  final String? chapterName;
  final String? chapterUrl;
  final String? formatJs;
  final String? isVolume;
  final String? isVip;
  final String? isPay;
  final String? updateTime;
  final String? nextTocUrl;

  @override
  Map<String, Object?> toJson() => {
        'preUpdateJs': preUpdateJs,
        'chapterList': chapterList,
        'chapterName': chapterName,
        'chapterUrl': chapterUrl,
        'formatJs': formatJs,
        'isVolume': isVolume,
        'isVip': isVip,
        'isPay': isPay,
        'updateTime': updateTime,
        'nextTocUrl': nextTocUrl,
      };
}

/// 正文页规则（`ruleContent`）。
class ContentRule extends JsonRuleBlock {
  const ContentRule({
    this.content,
    this.title,
    this.nextContentUrl,
    this.webJs,
    this.sourceRegex,
    this.replaceRegex,
    this.imageStyle,
    this.imageDecode,
    this.payAction,
  });

  factory ContentRule.fromJson(Map<String, Object?> json) => ContentRule(
        content: jsonString(json['content']),
        title: jsonString(json['title']),
        nextContentUrl: jsonString(json['nextContentUrl']),
        webJs: jsonString(json['webJs']),
        sourceRegex: jsonString(json['sourceRegex']),
        replaceRegex: jsonString(json['replaceRegex']),
        imageStyle: jsonString(json['imageStyle']),
        imageDecode: jsonString(json['imageDecode']),
        payAction: jsonString(json['payAction']),
      );

  final String? content;
  final String? title;
  final String? nextContentUrl;
  final String? webJs;
  final String? sourceRegex;
  final String? replaceRegex;
  final String? imageStyle;
  final String? imageDecode;
  final String? payAction;

  @override
  Map<String, Object?> toJson() => {
        'content': content,
        'title': title,
        'nextContentUrl': nextContentUrl,
        'webJs': webJs,
        'sourceRegex': sourceRegex,
        'replaceRegex': replaceRegex,
        'imageStyle': imageStyle,
        'imageDecode': imageDecode,
        'payAction': payAction,
      };
}

/// 发现页结果规则（`ruleExplore`）。字段集与 [SearchRule] 相同，只少了 `checkKeyWord`。
class ExploreRule extends JsonRuleBlock {
  const ExploreRule({
    this.bookList,
    this.name,
    this.author,
    this.intro,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.bookUrl,
    this.coverUrl,
    this.wordCount,
  });

  factory ExploreRule.fromJson(Map<String, Object?> json) => ExploreRule(
        bookList: jsonString(json['bookList']),
        name: jsonString(json['name']),
        author: jsonString(json['author']),
        intro: jsonString(json['intro']),
        kind: jsonString(json['kind']),
        lastChapter: jsonString(json['lastChapter']),
        updateTime: jsonString(json['updateTime']),
        bookUrl: jsonString(json['bookUrl']),
        coverUrl: jsonString(json['coverUrl']),
        wordCount: jsonString(json['wordCount']),
      );

  final String? bookList;
  final String? name;
  final String? author;
  final String? intro;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final String? bookUrl;
  final String? coverUrl;
  final String? wordCount;

  @override
  Map<String, Object?> toJson() => {
        'bookList': bookList,
        'name': name,
        'author': author,
        'intro': intro,
        'kind': kind,
        'lastChapter': lastChapter,
        'updateTime': updateTime,
        'bookUrl': bookUrl,
        'coverUrl': coverUrl,
        'wordCount': wordCount,
      };
}

/// 单条 URL 规则（发现页分类、搜索页）。
///
/// 对应 Kotlin 的 `AnalyzeUrl.UrlOption` + 发现页的 `ExploreUrl`
/// （后者在原仓库里只以 JSON 形式存在，没有独立实体类）。
class UrlOption extends JsonRuleBlock {
  const UrlOption({
    this.title,
    this.url,
    this.style,
    this.method,
    this.charset,
    this.headers,
    this.body,
    this.origin,
    this.retry,
    this.type,
    this.webView,
    this.webJs,
    this.js,
    this.serverID,
    this.webViewDelayTime,
  });

  factory UrlOption.fromJson(Map<String, Object?> json) => UrlOption(
        title: jsonString(json['title']),
        url: jsonString(json['url']),
        style: json['style'] is Map
            ? Map<String, Object?>.from(json['style'] as Map)
            : null,
        method: jsonString(json['method']),
        charset: jsonString(json['charset']),
        headers: json['headers'] is Map
            ? Map<String, Object?>.from(json['headers'] as Map)
            : json['headers'] is String
                ? jsonString(json['headers'])
                : null,
        body: json['body'],
        origin: jsonString(json['origin']),
        retry: json['retry'] == null ? null : _asInt(json['retry']),
        type: jsonString(json['type']),
        webView: json['webView'],
        webJs: jsonString(json['webJs']),
        js: jsonString(json['js']),
        serverID: json['serverID'] == null ? null : _asInt(json['serverID']),
        webViewDelayTime: json['webViewDelayTime'] == null
            ? null
            : _asInt(json['webViewDelayTime']),
      );

  /// 只写了 url 字符串时，包成一个最简选项（发现页大量书源这么写）。
  factory UrlOption.ofUrl(String url, {String? title}) =>
      UrlOption(url: url, title: title);

  final String? title;
  final String? url;

  /// 发现页分类的布局样式（`layout_flexBasisPercent` 等），规则层不使用，原样透传。
  final Map<String, Object?>? style;
  final String? method;
  final String? charset;
  final Object? headers;
  final Object? body;
  final String? origin;
  final int? retry;
  final String? type;
  final Object? webView;
  final String? webJs;
  final String? js;
  final int? serverID;
  final int? webViewDelayTime;

  bool get isPost => (method ?? '').toUpperCase() == 'POST';

  /// 对齐 Kotlin `UrlOption.useWebView()`：null/""/false/"false" 都算关闭。
  bool get useWebView {
    final v = webView;
    if (v == null) return false;
    if (v is bool) return v;
    if (v is String) return v.isNotEmpty && v != 'false';
    return true;
  }

  @override
  Map<String, Object?> toJson() => {
        'title': title,
        'url': url,
        'style': style,
        'method': method,
        'charset': charset,
        'headers': headers,
        'body': body,
        'origin': origin,
        'retry': retry,
        'type': type,
        'webView': webView,
        'webJs': webJs,
        'js': js,
        'serverID': serverID,
        'webViewDelayTime': webViewDelayTime,
      };
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString().trim());
}

/// URL 层规则（`searchUrl` / `exploreUrl` / `bookUrlPattern`）。
///
/// `searchUrl` 在书源里是一个字符串（可能内嵌 `{{}}`），`exploreUrl` 是一个
/// JSON 数组。这里统一成 [List<UrlOption>]：单条字符串规则会被包成一个选项，
/// 调用方不必再关心原始写法。
class UrlRule extends JsonRuleBlock {
  const UrlRule({
    this.searchUrl = const [],
    this.exploreUrl = const [],
    this.searchUrlRaw,
    this.exploreUrlRaw,
    this.bookUrlPattern,
  });

  factory UrlRule.fromJson(Map<String, Object?> json) => UrlRule(
        searchUrl: parseSearchUrl(jsonString(json['searchUrl'])),
        exploreUrl: parseExploreUrl(jsonString(json['exploreUrl'])),
        searchUrlRaw: jsonString(json['searchUrl']),
        exploreUrlRaw: jsonString(json['exploreUrl']),
        bookUrlPattern: jsonString(json['bookUrlPattern']),
      );

  final List<UrlOption> searchUrl;
  final List<UrlOption> exploreUrl;

  /// 原始写法，便于回写书源时不丢格式。
  final String? searchUrlRaw;
  final String? exploreUrlRaw;
  final String? bookUrlPattern;

  bool get hasSearch => searchUrl.isNotEmpty;
  bool get hasExplore => exploreUrl.isNotEmpty;

  @override
  Map<String, Object?> toJson() => {
        'searchUrl': searchUrlRaw,
        'exploreUrl': exploreUrlRaw,
        'bookUrlPattern': bookUrlPattern,
      };
}

/// 解析 `searchUrl`：多数书源是裸 URL 字符串，少数写成 `[{...}]`。
List<UrlOption> parseSearchUrl(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  final list = parseUrlOptionList(raw);
  if (list.isNotEmpty) return list;
  return [UrlOption.ofUrl(raw)];
}

/// 解析 `exploreUrl`：JSON 数组（宽松解析），数组项可以只有 `url`。
List<UrlOption> parseExploreUrl(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const [];
  final list = parseUrlOptionList(raw);
  if (list.isNotEmpty) return list;
  return [UrlOption.ofUrl(raw)];
}

/// 宽松解析 UrlOption 数组。
///
/// 书源里普遍存在多余逗号（`[{...},{...},]`）、单引号、未加引号的键，
/// Kotlin 侧先走 GSONStrict 再回退 GSON lenient；这里直接做一次宽松修复。
List<UrlOption> parseUrlOptionList(String raw) {
  final text = raw.trim();
  if (!text.startsWith('[')) return const [];
  final fixed = lenientJson(text.replaceAllMapped(RegExp(r',\s*([\]}])'), (m) => m[1]!));
  final decoded = _tryDecode(fixed);
  if (decoded is! List) return const [];
  final out = <UrlOption>[];
  for (final item in decoded) {
    if (item is Map) {
      out.add(UrlOption.fromJson(Map<String, Object?>.from(item)));
    } else if (item is String) {
      out.add(UrlOption.ofUrl(item));
    }
  }
  return out;
}

/// 宽松 JSON 修复：单引号字符串 → 双引号、未加引号的键 → 加引号。
///
/// 只在解析书源规则串时使用，不用于一般数据（改坏真实 JSON 的风险不值得）。
String lenientJson(String text) {
  final sb = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\\' && i + 1 < text.length) {
      sb.write(c);
      sb.write(text[i + 1]);
      i++;
      continue;
    }
    if (c == "'" && !inDouble) {
      inSingle = !inSingle;
      sb.write('"');
      continue;
    }
    if (c == '"' && !inSingle) {
      inDouble = !inDouble;
      sb.write(c);
      continue;
    }
    sb.write(c);
  }
  var out = sb.toString();
  // 未加引号的键：{ key: 或 , key:
  out = out.replaceAllMapped(
    RegExp(r'([{,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)\s*:'),
    (m) => '${m[1]}"${m[2]}":',
  );
  return out;
}

Object? _tryDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}
