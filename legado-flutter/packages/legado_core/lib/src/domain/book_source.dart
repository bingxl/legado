import 'dart:convert';

import 'row_utils.dart';

/// 分组字符串的分隔符，对应 Kotlin `AppPattern.splitGroupRegex = [,;，；]`。
final RegExp splitGroupRegex = RegExp('[,;，；]');

List<String> _splitGroups(String? raw) {
  if (raw == null) return const [];
  return raw
      .split(splitGroupRegex)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

const Object _unset = Object();

/// 书源。
///
/// Kotlin 侧规则字段（`ruleExplore` 等）是对象，由 `TypeConverters` 序列化成 JSON 存 TEXT。
/// 规则对象定义在 M2 的 `rules/` 里，数据层不重复实现一遍，因此这里保留**原始 JSON 字符串**，
/// 并提供 [fromJson] / [toJson] / [patchRaw] 做「整份书源 JSON」与列之间的转换。
///
/// 表 `book_sources` 的 `book_sources_part` 是视图，由 SQLite 现算，不存在冗余列需要手工刷新
/// —— 改任何字段后视图自动跟着变（见 [BookSourcePart.createSql]）。
class BookSource {
  BookSource({
    this.bookSourceUrl = '',
    this.bookSourceName = '',
    this.bookSourceGroup,
    this.bookSourceType = 0,
    this.bookUrlPattern,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.bookSourceComment,
    this.variableComment,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.exploreUrl,
    this.exploreScreen,
    this.ruleExplore,
    this.searchUrl,
    this.ruleSearch,
    this.ruleBookInfo,
    this.ruleToc,
    this.ruleContent,
    this.ruleReview,
  });

  static const String tableBookSources = 'book_sources';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `book_sources` (
  `bookSourceUrl` TEXT NOT NULL,
  `bookSourceName` TEXT NOT NULL,
  `bookSourceGroup` TEXT,
  `bookSourceType` INTEGER NOT NULL,
  `bookUrlPattern` TEXT,
  `customOrder` INTEGER NOT NULL DEFAULT 0,
  `enabled` INTEGER NOT NULL DEFAULT 1,
  `enabledExplore` INTEGER NOT NULL DEFAULT 1,
  `jsLib` TEXT,
  `enabledCookieJar` INTEGER DEFAULT 0,
  `concurrentRate` TEXT,
  `header` TEXT,
  `loginUrl` TEXT,
  `loginUi` TEXT,
  `loginCheckJs` TEXT,
  `coverDecodeJs` TEXT,
  `bookSourceComment` TEXT,
  `variableComment` TEXT,
  `lastUpdateTime` INTEGER NOT NULL,
  `respondTime` INTEGER NOT NULL,
  `weight` INTEGER NOT NULL,
  `exploreUrl` TEXT,
  `exploreScreen` TEXT,
  `ruleExplore` TEXT,
  `searchUrl` TEXT,
  `ruleSearch` TEXT,
  `ruleBookInfo` TEXT,
  `ruleToc` TEXT,
  `ruleContent` TEXT,
  `ruleReview` TEXT,
  PRIMARY KEY(`bookSourceUrl`)
)''';

  String bookSourceUrl;
  String bookSourceName;
  String? bookSourceGroup;

  /// 0 文本 / 1 音频 / 2 图片 / 3 文件，见 `BookSourceType`。
  int bookSourceType;

  /// 详情页 URL 正则；`'NONE'` 表示禁用。
  String? bookUrlPattern;
  int customOrder;
  bool enabled;
  bool enabledExplore;
  String? jsLib;

  /// 是否启用 CookieJar 自动保存。
  ///
  /// 注意 Kotlin 侧存在口径差异：实体默认 `true`，但 `@ColumnInfo(defaultValue = "0")`。
  /// 本类保持 Kotlin 实体默认 `true`（导入 JSON 缺字段时的行为），
  /// 建表 DDL 保持 Kotlin 的 `DEFAULT 0`（直接 SQL 插入且不带该列时的行为）。
  /// 我们的 DAO 始终显式写该列，所以日常路径不受影响。
  bool? enabledCookieJar;
  String? concurrentRate;
  String? header;
  String? loginUrl;
  String? loginUi;
  String? loginCheckJs;
  String? coverDecodeJs;
  String? bookSourceComment;
  String? variableComment;
  int lastUpdateTime;
  int respondTime;
  int weight;
  String? exploreUrl;
  String? exploreScreen;

  /// ExploreRule JSON。
  String? ruleExplore;
  String? searchUrl;

  /// SearchRule JSON。
  String? ruleSearch;

  /// BookInfoRule JSON。
  String? ruleBookInfo;

  /// TocRule JSON。
  String? ruleToc;

  /// ContentRule JSON。
  String? ruleContent;

  /// ReviewRule JSON。
  String? ruleReview;

  List<String> get groups => _splitGroups(bookSourceGroup);

  String get displayNameGroup =>
      (bookSourceGroup == null || bookSourceGroup!.isEmpty)
          ? bookSourceName
          : '$bookSourceName ($bookSourceGroup)';

  bool hasGroup(String group) => groups.contains(group);

  /// 合并分组，去重后按分隔符写回。
  void addGroup(String value) {
    final merged = {...groups, ..._splitGroups(value)};
    bookSourceGroup = merged.join(',');
  }

  void removeGroup(String value) {
    final removed = _splitGroups(value).toSet();
    bookSourceGroup = groups.where((g) => !removed.contains(g)).join(',');
  }

  factory BookSource.fromRow(Map<String, Object?> row) => BookSource(
        bookSourceUrl: asString(row['bookSourceUrl']),
        bookSourceName: asString(row['bookSourceName']),
        bookSourceGroup: asStringOrNull(row['bookSourceGroup']),
        bookSourceType: asInt(row['bookSourceType']),
        bookUrlPattern: asStringOrNull(row['bookUrlPattern']),
        customOrder: asInt(row['customOrder']),
        enabled: asBool(row['enabled'], fallback: true),
        enabledExplore: asBool(row['enabledExplore'], fallback: true),
        jsLib: asStringOrNull(row['jsLib']),
        enabledCookieJar: asBoolOrNull(row['enabledCookieJar']),
        concurrentRate: asStringOrNull(row['concurrentRate']),
        header: asStringOrNull(row['header']),
        loginUrl: asStringOrNull(row['loginUrl']),
        loginUi: asStringOrNull(row['loginUi']),
        loginCheckJs: asStringOrNull(row['loginCheckJs']),
        coverDecodeJs: asStringOrNull(row['coverDecodeJs']),
        bookSourceComment: asStringOrNull(row['bookSourceComment']),
        variableComment: asStringOrNull(row['variableComment']),
        lastUpdateTime: asInt(row['lastUpdateTime']),
        respondTime: asInt(row['respondTime'], 180000),
        weight: asInt(row['weight']),
        exploreUrl: asStringOrNull(row['exploreUrl']),
        exploreScreen: asStringOrNull(row['exploreScreen']),
        ruleExplore: asStringOrNull(row['ruleExplore']),
        searchUrl: asStringOrNull(row['searchUrl']),
        ruleSearch: asStringOrNull(row['ruleSearch']),
        ruleBookInfo: asStringOrNull(row['ruleBookInfo']),
        ruleToc: asStringOrNull(row['ruleToc']),
        ruleContent: asStringOrNull(row['ruleContent']),
        ruleReview: asStringOrNull(row['ruleReview']),
      );

  Map<String, Object?> toRow() => {
        'bookSourceUrl': bookSourceUrl,
        'bookSourceName': bookSourceName,
        'bookSourceGroup': bookSourceGroup,
        'bookSourceType': bookSourceType,
        'bookUrlPattern': bookUrlPattern,
        'customOrder': customOrder,
        'enabled': boolToInt(enabled),
        'enabledExplore': boolToInt(enabledExplore),
        'jsLib': jsLib,
        'enabledCookieJar': boolToIntOrNull(enabledCookieJar),
        'concurrentRate': concurrentRate,
        'header': header,
        'loginUrl': loginUrl,
        'loginUi': loginUi,
        'loginCheckJs': loginCheckJs,
        'coverDecodeJs': coverDecodeJs,
        'bookSourceComment': bookSourceComment,
        'variableComment': variableComment,
        'lastUpdateTime': lastUpdateTime,
        'respondTime': respondTime,
        'weight': weight,
        'exploreUrl': exploreUrl,
        'exploreScreen': exploreScreen,
        'ruleExplore': ruleExplore,
        'searchUrl': searchUrl,
        'ruleSearch': ruleSearch,
        'ruleBookInfo': ruleBookInfo,
        'ruleToc': ruleToc,
        'ruleContent': ruleContent,
        'ruleReview': ruleReview,
      };

  /// 从书源 JSON（导入文件里的单个对象）构造。
  ///
  /// 规则字段既接受嵌套对象，也接受已经是字符串的 JSON，导入两种格式都见过。
  factory BookSource.fromJson(Map<String, Object?> json) {
    String? jsonText(Object? value) {
      if (value == null) return null;
      if (value is String) return value;
      return jsonEncode(value);
    }

    return BookSource(
      bookSourceUrl: asString(json['bookSourceUrl']),
      bookSourceName: asString(json['bookSourceName']),
      bookSourceGroup: asStringOrNull(json['bookSourceGroup']),
      bookSourceType: asInt(json['bookSourceType']),
      bookUrlPattern: asStringOrNull(json['bookUrlPattern']),
      customOrder: asInt(json['customOrder']),
      enabled: asBool(json['enabled'], fallback: true),
      enabledExplore: asBool(json['enabledExplore'], fallback: true),
      jsLib: asStringOrNull(json['jsLib']),
      enabledCookieJar: asBoolOrNull(json['enabledCookieJar']),
      concurrentRate: asStringOrNull(json['concurrentRate']),
      header: asStringOrNull(json['header']),
      loginUrl: asStringOrNull(json['loginUrl']),
      loginUi: jsonText(json['loginUi']),
      loginCheckJs: asStringOrNull(json['loginCheckJs']),
      coverDecodeJs: asStringOrNull(json['coverDecodeJs']),
      bookSourceComment: asStringOrNull(json['bookSourceComment']),
      variableComment: asStringOrNull(json['variableComment']),
      lastUpdateTime: asInt(json['lastUpdateTime']),
      respondTime: asInt(json['respondTime'], 180000),
      weight: asInt(json['weight']),
      exploreUrl: asStringOrNull(json['exploreUrl']),
      exploreScreen: jsonText(json['exploreScreen']),
      ruleExplore: jsonText(json['ruleExplore']),
      searchUrl: asStringOrNull(json['searchUrl']),
      ruleSearch: jsonText(json['ruleSearch']),
      ruleBookInfo: jsonText(json['ruleBookInfo']),
      ruleToc: jsonText(json['ruleToc']),
      ruleContent: jsonText(json['ruleContent']),
      ruleReview: jsonText(json['ruleReview']),
    );
  }

  /// 导出为书源 JSON（规则字段还原成嵌套对象）。
  Map<String, Object?> toJson() {
    Object? decode(String? text) {
      if (text == null) return null;
      try {
        return jsonDecode(text);
      } on FormatException {
        return text;
      }
    }

    return {
      'bookSourceUrl': bookSourceUrl,
      'bookSourceName': bookSourceName,
      'bookSourceGroup': bookSourceGroup,
      'bookSourceType': bookSourceType,
      'bookUrlPattern': bookUrlPattern,
      'customOrder': customOrder,
      'enabled': enabled,
      'enabledExplore': enabledExplore,
      'jsLib': jsLib,
      'enabledCookieJar': enabledCookieJar,
      'concurrentRate': concurrentRate,
      'header': header,
      'loginUrl': loginUrl,
      'loginUi': decode(loginUi),
      'loginCheckJs': loginCheckJs,
      'coverDecodeJs': coverDecodeJs,
      'bookSourceComment': bookSourceComment,
      'variableComment': variableComment,
      'lastUpdateTime': lastUpdateTime,
      'respondTime': respondTime,
      'weight': weight,
      'exploreUrl': exploreUrl,
      'exploreScreen': decode(exploreScreen),
      'ruleExplore': decode(ruleExplore),
      'searchUrl': searchUrl,
      'ruleSearch': decode(ruleSearch),
      'ruleBookInfo': decode(ruleBookInfo),
      'ruleToc': decode(ruleToc),
      'ruleContent': decode(ruleContent),
      'ruleReview': decode(ruleReview),
    };
  }

  /// 把「书源 JSON 里改动的字段」合并回实体。
  ///
  /// 用于书源编辑：UI 传回整份 JSON 或差分，规则字段要重新序列化，
  /// 标量字段要按数据库类型收紧（Bool/Int），否则 `enabled: "false"` 会被当成 `true`。
  ///
  /// 返回自身，方便链式调用；要「不修改原对象」请先 `BookSource.fromRow(src.toRow())`。
  BookSource patchRaw(Map<String, Object?> changes) {
    String? asJsonText(Object? value) {
      if (value == null) return null;
      if (value is String) return value;
      return jsonEncode(value);
    }

    for (final entry in changes.entries) {
      final value = entry.value;
      switch (entry.key) {
        case 'bookSourceUrl':
          bookSourceUrl = asString(value, bookSourceUrl);
        case 'bookSourceName':
          bookSourceName = asString(value, bookSourceName);
        case 'bookSourceGroup':
          bookSourceGroup = asStringOrNull(value);
        case 'bookSourceType':
          bookSourceType = asInt(value, bookSourceType);
        case 'bookUrlPattern':
          bookUrlPattern = asStringOrNull(value);
        case 'customOrder':
          customOrder = asInt(value, customOrder);
        case 'enabled':
          enabled = asBool(value, fallback: enabled);
        case 'enabledExplore':
          enabledExplore = asBool(value, fallback: enabledExplore);
        case 'jsLib':
          jsLib = asStringOrNull(value);
        case 'enabledCookieJar':
          enabledCookieJar = asBoolOrNull(value);
        case 'concurrentRate':
          concurrentRate = asStringOrNull(value);
        case 'header':
          header = asStringOrNull(value);
        case 'loginUrl':
          loginUrl = asStringOrNull(value);
        case 'loginUi':
          loginUi = asJsonText(value);
        case 'loginCheckJs':
          loginCheckJs = asStringOrNull(value);
        case 'coverDecodeJs':
          coverDecodeJs = asStringOrNull(value);
        case 'bookSourceComment':
          bookSourceComment = asStringOrNull(value);
        case 'variableComment':
          variableComment = asStringOrNull(value);
        case 'lastUpdateTime':
          lastUpdateTime = asInt(value, lastUpdateTime);
        case 'respondTime':
          respondTime = asInt(value, respondTime);
        case 'weight':
          weight = asInt(value, weight);
        case 'exploreUrl':
          exploreUrl = asStringOrNull(value);
        case 'exploreScreen':
          exploreScreen = asJsonText(value);
        case 'ruleExplore':
          ruleExplore = asJsonText(value);
        case 'searchUrl':
          searchUrl = asStringOrNull(value);
        case 'ruleSearch':
          ruleSearch = asJsonText(value);
        case 'ruleBookInfo':
          ruleBookInfo = asJsonText(value);
        case 'ruleToc':
          ruleToc = asJsonText(value);
        case 'ruleContent':
          ruleContent = asJsonText(value);
        case 'ruleReview':
          ruleReview = asJsonText(value);
        default:
          // 未知字段忽略：导入第三方书源时经常带旧版本残留键。
          break;
      }
    }
    return this;
  }

  BookSource copyWith({
    String? bookSourceUrl,
    String? bookSourceName,
    Object? bookSourceGroup = _unset,
    int? bookSourceType,
    Object? bookUrlPattern = _unset,
    int? customOrder,
    bool? enabled,
    bool? enabledExplore,
    Object? jsLib = _unset,
    Object? enabledCookieJar = _unset,
    Object? concurrentRate = _unset,
    Object? header = _unset,
    Object? loginUrl = _unset,
    Object? loginUi = _unset,
    Object? loginCheckJs = _unset,
    Object? coverDecodeJs = _unset,
    Object? bookSourceComment = _unset,
    Object? variableComment = _unset,
    int? lastUpdateTime,
    int? respondTime,
    int? weight,
    Object? exploreUrl = _unset,
    Object? exploreScreen = _unset,
    Object? ruleExplore = _unset,
    Object? searchUrl = _unset,
    Object? ruleSearch = _unset,
    Object? ruleBookInfo = _unset,
    Object? ruleToc = _unset,
    Object? ruleContent = _unset,
    Object? ruleReview = _unset,
  }) =>
      BookSource(
        bookSourceUrl: bookSourceUrl ?? this.bookSourceUrl,
        bookSourceName: bookSourceName ?? this.bookSourceName,
        bookSourceGroup: identical(bookSourceGroup, _unset)
            ? this.bookSourceGroup
            : bookSourceGroup as String?,
        bookSourceType: bookSourceType ?? this.bookSourceType,
        bookUrlPattern: identical(bookUrlPattern, _unset)
            ? this.bookUrlPattern
            : bookUrlPattern as String?,
        customOrder: customOrder ?? this.customOrder,
        enabled: enabled ?? this.enabled,
        enabledExplore: enabledExplore ?? this.enabledExplore,
        jsLib: identical(jsLib, _unset) ? this.jsLib : jsLib as String?,
        enabledCookieJar: identical(enabledCookieJar, _unset)
            ? this.enabledCookieJar
            : enabledCookieJar as bool?,
        concurrentRate:
            identical(concurrentRate, _unset) ? this.concurrentRate : concurrentRate as String?,
        header: identical(header, _unset) ? this.header : header as String?,
        loginUrl: identical(loginUrl, _unset) ? this.loginUrl : loginUrl as String?,
        loginUi: identical(loginUi, _unset) ? this.loginUi : loginUi as String?,
        loginCheckJs:
            identical(loginCheckJs, _unset) ? this.loginCheckJs : loginCheckJs as String?,
        coverDecodeJs:
            identical(coverDecodeJs, _unset) ? this.coverDecodeJs : coverDecodeJs as String?,
        bookSourceComment: identical(bookSourceComment, _unset)
            ? this.bookSourceComment
            : bookSourceComment as String?,
        variableComment: identical(variableComment, _unset)
            ? this.variableComment
            : variableComment as String?,
        lastUpdateTime: lastUpdateTime ?? this.lastUpdateTime,
        respondTime: respondTime ?? this.respondTime,
        weight: weight ?? this.weight,
        exploreUrl: identical(exploreUrl, _unset) ? this.exploreUrl : exploreUrl as String?,
        exploreScreen:
            identical(exploreScreen, _unset) ? this.exploreScreen : exploreScreen as String?,
        ruleExplore: identical(ruleExplore, _unset) ? this.ruleExplore : ruleExplore as String?,
        searchUrl: identical(searchUrl, _unset) ? this.searchUrl : searchUrl as String?,
        ruleSearch: identical(ruleSearch, _unset) ? this.ruleSearch : ruleSearch as String?,
        ruleBookInfo:
            identical(ruleBookInfo, _unset) ? this.ruleBookInfo : ruleBookInfo as String?,
        ruleToc: identical(ruleToc, _unset) ? this.ruleToc : ruleToc as String?,
        ruleContent: identical(ruleContent, _unset) ? this.ruleContent : ruleContent as String?,
        ruleReview: identical(ruleReview, _unset) ? this.ruleReview : ruleReview as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is BookSource && other.bookSourceUrl == bookSourceUrl;

  @override
  int get hashCode => bookSourceUrl.hashCode;
}

/// 书源的「分组列」视图，对应 Kotlin `@DatabaseView book_sources_part`。
///
/// 只读：写操作请走 [BookSource]。`hasLoginUrl` / `hasExploreUrl` 由 SQL 现算，
/// 所以不存在「改了 loginUrl 忘了刷新冗余列」的问题。
class BookSourcePart {
  BookSourcePart({
    this.bookSourceUrl = '',
    this.bookSourceName = '',
    this.bookSourceGroup,
    this.customOrder = 0,
    this.enabled = true,
    this.enabledExplore = true,
    this.hasLoginUrl = false,
    this.lastUpdateTime = 0,
    this.respondTime = 180000,
    this.weight = 0,
    this.hasExploreUrl = false,
    this.hasSearchUrl = false,
  });

  static const String viewBookSourcesPart = 'book_sources_part';

  static const String createSql = '''
CREATE VIEW IF NOT EXISTS `book_sources_part` AS
select bookSourceUrl, bookSourceName, bookSourceGroup, customOrder, enabled, enabledExplore,
  (loginUrl is not null and trim(loginUrl) <> '') hasLoginUrl, lastUpdateTime, respondTime, weight,
  (exploreUrl is not null and trim(exploreUrl) <> '') hasExploreUrl,
  (searchUrl is not null and trim(searchUrl) <> '') hasSearchUrl
from book_sources''';

  String bookSourceUrl;
  String bookSourceName;
  String? bookSourceGroup;
  int customOrder;
  bool enabled;
  bool enabledExplore;
  bool hasLoginUrl;
  int lastUpdateTime;
  int respondTime;
  int weight;
  bool hasExploreUrl;

  /// 是否配置了搜索地址（纯发现源为 false）。
  bool hasSearchUrl;

  String get displayNameGroup =>
      (bookSourceGroup == null || bookSourceGroup!.isEmpty)
          ? bookSourceName
          : '$bookSourceName ($bookSourceGroup)';

  factory BookSourcePart.fromRow(Map<String, Object?> row) => BookSourcePart(
        bookSourceUrl: asString(row['bookSourceUrl']),
        bookSourceName: asString(row['bookSourceName']),
        bookSourceGroup: asStringOrNull(row['bookSourceGroup']),
        customOrder: asInt(row['customOrder']),
        enabled: asBool(row['enabled'], fallback: true),
        enabledExplore: asBool(row['enabledExplore'], fallback: true),
        hasLoginUrl: asBool(row['hasLoginUrl']),
        lastUpdateTime: asInt(row['lastUpdateTime']),
        respondTime: asInt(row['respondTime'], 180000),
        weight: asInt(row['weight']),
        hasExploreUrl: asBool(row['hasExploreUrl']),
        hasSearchUrl: asBool(row['hasSearchUrl']),
      );

  @override
  bool operator ==(Object other) =>
      other is BookSourcePart && other.bookSourceUrl == bookSourceUrl;

  @override
  int get hashCode => bookSourceUrl.hashCode;
}
