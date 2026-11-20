import 'book_source.dart' show splitGroupRegex;
import 'row_utils.dart';

/// RSS 源。
///
/// 规则字段（ruleArticles 等）在 Kotlin 里就是 String（直接写规则表达式），
/// 不像书源那样转 JSON 对象，所以这里保持 String。
class RssSource {
  RssSource({
    this.sourceUrl = '',
    this.sourceName = '',
    this.sourceIcon = '',
    this.sourceGroup,
    this.sourceComment,
    this.enabled = true,
    this.variableComment,
    this.jsLib,
    this.enabledCookieJar = true,
    this.concurrentRate,
    this.header,
    this.loginUrl,
    this.loginUi,
    this.loginCheckJs,
    this.coverDecodeJs,
    this.sortUrl,
    this.singleUrl = false,
    this.articleStyle = 0,
    this.ruleArticles,
    this.ruleNextPage,
    this.ruleTitle,
    this.rulePubDate,
    this.ruleDescription,
    this.ruleImage,
    this.ruleLink,
    this.ruleContent,
    this.contentWhitelist,
    this.contentBlacklist,
    this.shouldOverrideUrlLoading,
    this.style,
    this.enableJs = true,
    this.loadWithBaseUrl = true,
    this.injectJs,
    this.lastUpdateTime = 0,
    this.customOrder = 0,
  });

  static const String tableRssSources = 'rssSources';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `rssSources` (
  `sourceUrl` TEXT NOT NULL,
  `sourceName` TEXT NOT NULL,
  `sourceIcon` TEXT NOT NULL,
  `sourceGroup` TEXT,
  `sourceComment` TEXT,
  `enabled` INTEGER NOT NULL,
  `variableComment` TEXT,
  `jsLib` TEXT,
  `enabledCookieJar` INTEGER DEFAULT 0,
  `concurrentRate` TEXT,
  `header` TEXT,
  `loginUrl` TEXT,
  `loginUi` TEXT,
  `loginCheckJs` TEXT,
  `coverDecodeJs` TEXT,
  `sortUrl` TEXT,
  `singleUrl` INTEGER NOT NULL,
  `articleStyle` INTEGER NOT NULL DEFAULT 0,
  `ruleArticles` TEXT,
  `ruleNextPage` TEXT,
  `ruleTitle` TEXT,
  `rulePubDate` TEXT,
  `ruleDescription` TEXT,
  `ruleImage` TEXT,
  `ruleLink` TEXT,
  `ruleContent` TEXT,
  `contentWhitelist` TEXT,
  `contentBlacklist` TEXT,
  `shouldOverrideUrlLoading` TEXT,
  `style` TEXT,
  `enableJs` INTEGER NOT NULL DEFAULT 1,
  `loadWithBaseUrl` INTEGER NOT NULL DEFAULT 1,
  `injectJs` TEXT,
  `lastUpdateTime` INTEGER NOT NULL DEFAULT 0,
  `customOrder` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`sourceUrl`)
)''';

  String sourceUrl;
  String sourceName;
  String sourceIcon;
  String? sourceGroup;
  String? sourceComment;
  bool enabled;
  String? variableComment;
  String? jsLib;
  bool? enabledCookieJar;
  String? concurrentRate;
  String? header;
  String? loginUrl;
  String? loginUi;
  String? loginCheckJs;
  String? coverDecodeJs;
  String? sortUrl;

  /// 是否单 URL 源。
  bool singleUrl;

  /// 列表样式 0/1/2。
  int articleStyle;
  String? ruleArticles;
  String? ruleNextPage;
  String? ruleTitle;
  String? rulePubDate;
  String? ruleDescription;
  String? ruleImage;
  String? ruleLink;
  String? ruleContent;
  String? contentWhitelist;
  String? contentBlacklist;
  String? shouldOverrideUrlLoading;
  String? style;
  bool enableJs;
  bool loadWithBaseUrl;
  String? injectJs;
  int lastUpdateTime;
  int customOrder;

  List<String> get groups {
    final raw = sourceGroup;
    if (raw == null) return const [];
    return raw
        .split(splitGroupRegex)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  String get displayNameGroup =>
      (sourceGroup == null || sourceGroup!.isEmpty)
          ? sourceName
          : '$sourceName ($sourceGroup)';

  factory RssSource.fromRow(Map<String, Object?> row) => RssSource(
        sourceUrl: asString(row['sourceUrl']),
        sourceName: asString(row['sourceName']),
        sourceIcon: asString(row['sourceIcon']),
        sourceGroup: asStringOrNull(row['sourceGroup']),
        sourceComment: asStringOrNull(row['sourceComment']),
        enabled: asBool(row['enabled'], fallback: true),
        variableComment: asStringOrNull(row['variableComment']),
        jsLib: asStringOrNull(row['jsLib']),
        enabledCookieJar: asBoolOrNull(row['enabledCookieJar']),
        concurrentRate: asStringOrNull(row['concurrentRate']),
        header: asStringOrNull(row['header']),
        loginUrl: asStringOrNull(row['loginUrl']),
        loginUi: asStringOrNull(row['loginUi']),
        loginCheckJs: asStringOrNull(row['loginCheckJs']),
        coverDecodeJs: asStringOrNull(row['coverDecodeJs']),
        sortUrl: asStringOrNull(row['sortUrl']),
        singleUrl: asBool(row['singleUrl']),
        articleStyle: asInt(row['articleStyle']),
        ruleArticles: asStringOrNull(row['ruleArticles']),
        ruleNextPage: asStringOrNull(row['ruleNextPage']),
        ruleTitle: asStringOrNull(row['ruleTitle']),
        rulePubDate: asStringOrNull(row['rulePubDate']),
        ruleDescription: asStringOrNull(row['ruleDescription']),
        ruleImage: asStringOrNull(row['ruleImage']),
        ruleLink: asStringOrNull(row['ruleLink']),
        ruleContent: asStringOrNull(row['ruleContent']),
        contentWhitelist: asStringOrNull(row['contentWhitelist']),
        contentBlacklist: asStringOrNull(row['contentBlacklist']),
        shouldOverrideUrlLoading: asStringOrNull(row['shouldOverrideUrlLoading']),
        style: asStringOrNull(row['style']),
        enableJs: asBool(row['enableJs'], fallback: true),
        loadWithBaseUrl: asBool(row['loadWithBaseUrl'], fallback: true),
        injectJs: asStringOrNull(row['injectJs']),
        lastUpdateTime: asInt(row['lastUpdateTime']),
        customOrder: asInt(row['customOrder']),
      );

  Map<String, Object?> toRow() => {
        'sourceUrl': sourceUrl,
        'sourceName': sourceName,
        'sourceIcon': sourceIcon,
        'sourceGroup': sourceGroup,
        'sourceComment': sourceComment,
        'enabled': boolToInt(enabled),
        'variableComment': variableComment,
        'jsLib': jsLib,
        'enabledCookieJar': boolToIntOrNull(enabledCookieJar),
        'concurrentRate': concurrentRate,
        'header': header,
        'loginUrl': loginUrl,
        'loginUi': loginUi,
        'loginCheckJs': loginCheckJs,
        'coverDecodeJs': coverDecodeJs,
        'sortUrl': sortUrl,
        'singleUrl': boolToInt(singleUrl),
        'articleStyle': articleStyle,
        'ruleArticles': ruleArticles,
        'ruleNextPage': ruleNextPage,
        'ruleTitle': ruleTitle,
        'rulePubDate': rulePubDate,
        'ruleDescription': ruleDescription,
        'ruleImage': ruleImage,
        'ruleLink': ruleLink,
        'ruleContent': ruleContent,
        'contentWhitelist': contentWhitelist,
        'contentBlacklist': contentBlacklist,
        'shouldOverrideUrlLoading': shouldOverrideUrlLoading,
        'style': style,
        'enableJs': boolToInt(enableJs),
        'loadWithBaseUrl': boolToInt(loadWithBaseUrl),
        'injectJs': injectJs,
        'lastUpdateTime': lastUpdateTime,
        'customOrder': customOrder,
      };

  @override
  bool operator ==(Object other) => other is RssSource && other.sourceUrl == sourceUrl;

  @override
  int get hashCode => sourceUrl.hashCode;
}

/// RSS 文章，主键 `(origin, link)`。
class RssArticle {
  RssArticle({
    this.origin = '',
    this.sort = '',
    this.title = '',
    this.order = 0,
    this.link = '',
    this.pubDate,
    this.description,
    this.content,
    this.image,
    this.group = '默认分组',
    this.read = false,
    this.variable,
  });

  static const String tableRssArticles = 'rssArticles';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `rssArticles` (
  `origin` TEXT NOT NULL,
  `sort` TEXT NOT NULL,
  `title` TEXT NOT NULL,
  `order` INTEGER NOT NULL,
  `link` TEXT NOT NULL,
  `pubDate` TEXT,
  `description` TEXT,
  `content` TEXT,
  `image` TEXT,
  `group` TEXT NOT NULL DEFAULT '默认分组',
  `read` INTEGER NOT NULL,
  `variable` TEXT,
  PRIMARY KEY(`origin`, `link`)
)''';

  String origin;
  String sort;
  String title;
  int order;
  String link;
  String? pubDate;
  String? description;
  String? content;
  String? image;
  String group;
  bool read;
  String? variable;

  factory RssArticle.fromRow(Map<String, Object?> row) => RssArticle(
        origin: asString(row['origin']),
        sort: asString(row['sort']),
        title: asString(row['title']),
        order: asInt(row['order']),
        link: asString(row['link']),
        pubDate: asStringOrNull(row['pubDate']),
        description: asStringOrNull(row['description']),
        content: asStringOrNull(row['content']),
        image: asStringOrNull(row['image']),
        group: asString(row['group'], '默认分组'),
        read: asBool(row['read']),
        variable: asStringOrNull(row['variable']),
      );

  Map<String, Object?> toRow() => {
        'origin': origin,
        'sort': sort,
        'title': title,
        'order': order,
        'link': link,
        'pubDate': pubDate,
        'description': description,
        'content': content,
        'image': image,
        'group': group,
        'read': boolToInt(read),
        'variable': variable,
      };

  @override
  bool operator ==(Object other) =>
      other is RssArticle && other.origin == origin && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// RSS 收藏，主键 `(origin, link)`。
class RssStar {
  RssStar({
    this.origin = '',
    this.sort = '',
    this.title = '',
    this.starTime = 0,
    this.link = '',
    this.pubDate,
    this.description,
    this.content,
    this.image,
    this.group = '默认分组',
    this.variable,
  });

  static const String tableRssStars = 'rssStars';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `rssStars` (
  `origin` TEXT NOT NULL,
  `sort` TEXT NOT NULL,
  `title` TEXT NOT NULL,
  `starTime` INTEGER NOT NULL,
  `link` TEXT NOT NULL,
  `pubDate` TEXT,
  `description` TEXT,
  `content` TEXT,
  `image` TEXT,
  `group` TEXT NOT NULL DEFAULT '默认分组',
  `variable` TEXT,
  PRIMARY KEY(`origin`, `link`)
)''';

  String origin;
  String sort;
  String title;
  int starTime;
  String link;
  String? pubDate;
  String? description;
  String? content;
  String? image;
  String group;
  String? variable;

  factory RssStar.fromRow(Map<String, Object?> row) => RssStar(
        origin: asString(row['origin']),
        sort: asString(row['sort']),
        title: asString(row['title']),
        starTime: asInt(row['starTime']),
        link: asString(row['link']),
        pubDate: asStringOrNull(row['pubDate']),
        description: asStringOrNull(row['description']),
        content: asStringOrNull(row['content']),
        image: asStringOrNull(row['image']),
        group: asString(row['group'], '默认分组'),
        variable: asStringOrNull(row['variable']),
      );

  Map<String, Object?> toRow() => {
        'origin': origin,
        'sort': sort,
        'title': title,
        'starTime': starTime,
        'link': link,
        'pubDate': pubDate,
        'description': description,
        'content': content,
        'image': image,
        'group': group,
        'variable': variable,
      };

  @override
  bool operator ==(Object other) =>
      other is RssStar && other.origin == origin && other.link == link;

  @override
  int get hashCode => link.hashCode;
}

/// RSS 已读记录。
class RssReadRecord {
  RssReadRecord({
    required this.record,
    this.title,
    this.readTime,
    this.read = true,
  });

  static const String tableRssReadRecords = 'rssReadRecords';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `rssReadRecords` (
  `record` TEXT NOT NULL,
  `title` TEXT,
  `readTime` INTEGER,
  `read` INTEGER NOT NULL,
  PRIMARY KEY(`record`)
)''';

  String record;
  String? title;
  int? readTime;
  bool read;

  factory RssReadRecord.fromRow(Map<String, Object?> row) => RssReadRecord(
        record: asString(row['record']),
        title: asStringOrNull(row['title']),
        readTime: asIntOrNull(row['readTime']),
        read: asBool(row['read'], fallback: true),
      );

  Map<String, Object?> toRow() => {
        'record': record,
        'title': title,
        'readTime': readTime,
        'read': boolToInt(read),
      };
}
