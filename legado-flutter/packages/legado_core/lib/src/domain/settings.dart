import 'row_utils.dart';

const Object _unsetSetting = Object();

/// 替换净化规则。
///
/// `order` 在数据库里的列名是 `sortOrder`（Kotlin `@ColumnInfo(name="sortOrder")`），
/// 注意别按 Dart 字段名去拼 SQL。
class ReplaceRule {
  ReplaceRule({
    this.id = 0,
    this.name = '',
    this.group,
    this.pattern = '',
    this.replacement = '',
    this.scope,
    this.scopeTitle = false,
    this.scopeContent = true,
    this.excludeScope,
    this.isEnabled = true,
    this.isRegex = true,
    this.timeoutMillisecond = 3000,
    this.order = -2147483648,
  });

  static const String tableReplaceRules = 'replace_rules';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `replace_rules` (
  `id` INTEGER NOT NULL,
  `name` TEXT NOT NULL DEFAULT '',
  `group` TEXT,
  `pattern` TEXT NOT NULL DEFAULT '',
  `replacement` TEXT NOT NULL DEFAULT '',
  `scope` TEXT,
  `scopeTitle` INTEGER NOT NULL DEFAULT 0,
  `scopeContent` INTEGER NOT NULL DEFAULT 1,
  `excludeScope` TEXT,
  `isEnabled` INTEGER NOT NULL DEFAULT 1,
  `isRegex` INTEGER NOT NULL DEFAULT 1,
  `timeoutMillisecond` INTEGER NOT NULL DEFAULT 3000,
  `sortOrder` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`id`)
)''';

  int id;
  String name;
  String? group;
  String pattern;
  String replacement;

  /// 作用范围，匹配书名/书源。
  String? scope;
  bool scopeTitle;
  bool scopeContent;
  String? excludeScope;
  bool isEnabled;
  bool isRegex;
  int timeoutMillisecond;

  /// 排序，列名 `sortOrder`。
  int order;

  String get displayNameGroup =>
      (group == null || group!.isEmpty) ? name : '$name ($group)';

  bool get isValid {
    if (pattern.isEmpty) return false;
    if (isRegex && pattern.endsWith('|') && !pattern.endsWith(r'\|')) {
      return false;
    }
    return true;
  }

  factory ReplaceRule.fromRow(Map<String, Object?> row) => ReplaceRule(
        id: asInt(row['id']),
        name: asString(row['name']),
        group: asStringOrNull(row['group']),
        pattern: asString(row['pattern']),
        replacement: asString(row['replacement']),
        scope: asStringOrNull(row['scope']),
        scopeTitle: asBool(row['scopeTitle']),
        scopeContent: asBool(row['scopeContent'], fallback: true),
        excludeScope: asStringOrNull(row['excludeScope']),
        isEnabled: asBool(row['isEnabled'], fallback: true),
        isRegex: asBool(row['isRegex'], fallback: true),
        timeoutMillisecond: asInt(row['timeoutMillisecond'], 3000),
        order: asInt(row['sortOrder'], -2147483648),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'group': group,
        'pattern': pattern,
        'replacement': replacement,
        'scope': scope,
        'scopeTitle': boolToInt(scopeTitle),
        'scopeContent': boolToInt(scopeContent),
        'excludeScope': excludeScope,
        'isEnabled': boolToInt(isEnabled),
        'isRegex': boolToInt(isRegex),
        'timeoutMillisecond': timeoutMillisecond,
        'sortOrder': order,
      };

  ReplaceRule copyWith({
    int? id,
    String? name,
    Object? group = _unsetSetting,
    String? pattern,
    String? replacement,
    Object? scope = _unsetSetting,
    bool? scopeTitle,
    bool? scopeContent,
    Object? excludeScope = _unsetSetting,
    bool? isEnabled,
    bool? isRegex,
    int? timeoutMillisecond,
    int? order,
  }) =>
      ReplaceRule(
        id: id ?? this.id,
        name: name ?? this.name,
        group: identical(group, _unsetSetting) ? this.group : group as String?,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        scope: identical(scope, _unsetSetting) ? this.scope : scope as String?,
        scopeTitle: scopeTitle ?? this.scopeTitle,
        scopeContent: scopeContent ?? this.scopeContent,
        excludeScope:
            identical(excludeScope, _unsetSetting) ? this.excludeScope : excludeScope as String?,
        isEnabled: isEnabled ?? this.isEnabled,
        isRegex: isRegex ?? this.isRegex,
        timeoutMillisecond: timeoutMillisecond ?? this.timeoutMillisecond,
        order: order ?? this.order,
      );
}

/// 键值缓存（登录头、书源变量、用户信息等）。
class Cache {
  Cache({
    this.key = '',
    this.value,
    this.deadline = 0,
  });

  static const String tableCaches = 'caches';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `caches` (
  `key` TEXT NOT NULL,
  `value` TEXT,
  `deadline` INTEGER NOT NULL,
  PRIMARY KEY(`key`)
)''';

  String key;
  String? value;

  /// 毫秒时间戳；0 表示永不过期。
  int deadline;

  factory Cache.fromRow(Map<String, Object?> row) => Cache(
        key: asString(row['key']),
        value: asStringOrNull(row['value']),
        deadline: asInt(row['deadline']),
      );

  Map<String, Object?> toRow() => {
        'key': key,
        'value': value,
        'deadline': deadline,
      };
}

/// 字典规则。
class DictRule {
  DictRule({
    this.name = '',
    this.urlRule = '',
    this.showRule = '',
    this.enabled = true,
    this.sortNumber = 0,
  });

  static const String tableDictRules = 'dictRules';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `dictRules` (
  `name` TEXT NOT NULL,
  `urlRule` TEXT NOT NULL,
  `showRule` TEXT NOT NULL,
  `enabled` INTEGER NOT NULL DEFAULT 1,
  `sortNumber` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`name`)
)''';

  String name;
  String urlRule;
  String showRule;
  bool enabled;
  int sortNumber;

  factory DictRule.fromRow(Map<String, Object?> row) => DictRule(
        name: asString(row['name']),
        urlRule: asString(row['urlRule']),
        showRule: asString(row['showRule']),
        enabled: asBool(row['enabled'], fallback: true),
        sortNumber: asInt(row['sortNumber']),
      );

  Map<String, Object?> toRow() => {
        'name': name,
        'urlRule': urlRule,
        'showRule': showRule,
        'enabled': boolToInt(enabled),
        'sortNumber': sortNumber,
      };
}

/// 在线朗读引擎。
class HttpTTS {
  HttpTTS({
    this.id = 0,
    this.name = '',
    this.url = '',
    this.contentType,
    this.concurrentRate = '0',
    this.loginUrl,
    this.loginUi,
    this.header,
    this.jsLib,
    this.enabledCookieJar = false,
    this.loginCheckJs,
    this.lastUpdateTime = 0,
  });

  static const String tableHttpTts = 'httpTTS';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `httpTTS` (
  `id` INTEGER NOT NULL,
  `name` TEXT NOT NULL,
  `url` TEXT NOT NULL,
  `contentType` TEXT,
  `concurrentRate` TEXT DEFAULT '0',
  `loginUrl` TEXT,
  `loginUi` TEXT,
  `header` TEXT,
  `jsLib` TEXT,
  `enabledCookieJar` INTEGER DEFAULT 0,
  `loginCheckJs` TEXT,
  `lastUpdateTime` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`id`)
)''';

  int id;
  String name;
  String url;
  String? contentType;
  String? concurrentRate;
  String? loginUrl;
  String? loginUi;
  String? header;
  String? jsLib;
  bool? enabledCookieJar;
  String? loginCheckJs;
  int lastUpdateTime;

  String get key => 'httpTts:$id';

  factory HttpTTS.fromRow(Map<String, Object?> row) => HttpTTS(
        id: asInt(row['id']),
        name: asString(row['name']),
        url: asString(row['url']),
        contentType: asStringOrNull(row['contentType']),
        concurrentRate: asStringOrNull(row['concurrentRate']),
        loginUrl: asStringOrNull(row['loginUrl']),
        loginUi: asStringOrNull(row['loginUi']),
        header: asStringOrNull(row['header']),
        jsLib: asStringOrNull(row['jsLib']),
        enabledCookieJar: asBoolOrNull(row['enabledCookieJar']),
        loginCheckJs: asStringOrNull(row['loginCheckJs']),
        lastUpdateTime: asInt(row['lastUpdateTime']),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'url': url,
        'contentType': contentType,
        'concurrentRate': concurrentRate,
        'loginUrl': loginUrl,
        'loginUi': loginUi,
        'header': header,
        'jsLib': jsLib,
        'enabledCookieJar': boolToIntOrNull(enabledCookieJar),
        'loginCheckJs': loginCheckJs,
        'lastUpdateTime': lastUpdateTime,
      };
}

/// 订阅源（书源订阅 / 规则订阅）。
class RuleSub {
  RuleSub({
    this.id = 0,
    this.name = '',
    this.url = '',
    this.type = 0,
    this.customOrder = 0,
    this.autoUpdate = false,
    this.update = 0,
  });

  static const String tableRuleSubs = 'ruleSubs';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `ruleSubs` (
  `id` INTEGER NOT NULL,
  `name` TEXT NOT NULL,
  `url` TEXT NOT NULL,
  `type` INTEGER NOT NULL,
  `customOrder` INTEGER NOT NULL,
  `autoUpdate` INTEGER NOT NULL,
  `update` INTEGER NOT NULL,
  PRIMARY KEY(`id`)
)''';

  int id;
  String name;
  String url;
  int type;
  int customOrder;
  bool autoUpdate;
  int update;

  factory RuleSub.fromRow(Map<String, Object?> row) => RuleSub(
        id: asInt(row['id']),
        name: asString(row['name']),
        url: asString(row['url']),
        type: asInt(row['type']),
        customOrder: asInt(row['customOrder']),
        autoUpdate: asBool(row['autoUpdate']),
        update: asInt(row['update']),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'url': url,
        'type': type,
        'customOrder': customOrder,
        'autoUpdate': boolToInt(autoUpdate),
        'update': update,
      };
}

/// 服务器类型，对应 Kotlin `Server.TYPE`。
abstract final class ServerType {
  /// 数据库里存的是枚举名（Room 内置枚举转换器写 name）。
  static const String webdav = 'WEBDAV';
}

/// 同步服务器。
class Server {
  Server({
    this.id = 0,
    this.name = '',
    this.type = ServerType.webdav,
    this.config,
    this.sortNumber = 0,
  });

  static const String tableServers = 'servers';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `servers` (
  `id` INTEGER NOT NULL,
  `name` TEXT NOT NULL,
  `type` TEXT NOT NULL,
  `config` TEXT,
  `sortNumber` INTEGER NOT NULL,
  PRIMARY KEY(`id`)
)''';

  int id;
  String name;

  /// 见 [ServerType]。
  String type;

  /// 配置 JSON。
  String? config;
  int sortNumber;

  factory Server.fromRow(Map<String, Object?> row) => Server(
        id: asInt(row['id']),
        name: asString(row['name']),
        type: asString(row['type'], ServerType.webdav),
        config: asStringOrNull(row['config']),
        sortNumber: asInt(row['sortNumber']),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'type': type,
        'config': config,
        'sortNumber': sortNumber,
      };
}

/// TXT 目录规则。
class TxtTocRule {
  TxtTocRule({
    this.id = 0,
    this.name = '',
    this.rule = '',
    this.example,
    this.serialNumber = -1,
    this.enable = true,
  });

  static const String tableTxtTocRules = 'txtTocRules';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `txtTocRules` (
  `id` INTEGER NOT NULL,
  `name` TEXT NOT NULL,
  `rule` TEXT NOT NULL,
  `example` TEXT,
  `serialNumber` INTEGER NOT NULL,
  `enable` INTEGER NOT NULL,
  PRIMARY KEY(`id`)
)''';

  int id;
  String name;
  String rule;
  String? example;
  int serialNumber;
  bool enable;

  factory TxtTocRule.fromRow(Map<String, Object?> row) => TxtTocRule(
        id: asInt(row['id']),
        name: asString(row['name']),
        rule: asString(row['rule']),
        example: asStringOrNull(row['example']),
        serialNumber: asInt(row['serialNumber'], -1),
        enable: asBool(row['enable'], fallback: true),
      );

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'rule': rule,
        'example': example,
        'serialNumber': serialNumber,
        'enable': boolToInt(enable),
      };
}

/// Cookie。
class Cookie {
  Cookie({
    this.url = '',
    this.cookie = '',
  });

  static const String tableCookies = 'cookies';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `cookies` (
  `url` TEXT NOT NULL,
  `cookie` TEXT NOT NULL,
  PRIMARY KEY(`url`)
)''';

  String url;
  String cookie;

  factory Cookie.fromRow(Map<String, Object?> row) => Cookie(
        url: asString(row['url']),
        cookie: asString(row['cookie']),
      );

  Map<String, Object?> toRow() => {
        'url': url,
        'cookie': cookie,
      };
}

/// 键盘快捷输入（阅读界面自定义按键）。
class KeyboardAssist {
  KeyboardAssist({
    this.type = 0,
    this.key = '',
    this.value = '',
    this.serialNo = 0,
  });

  static const String tableKeyboardAssists = 'keyboardAssists';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `keyboardAssists` (
  `type` INTEGER NOT NULL DEFAULT 0,
  `key` TEXT NOT NULL DEFAULT '',
  `value` TEXT NOT NULL DEFAULT '',
  `serialNo` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`type`, `key`)
)''';

  int type;
  String key;
  String value;
  int serialNo;

  factory KeyboardAssist.fromRow(Map<String, Object?> row) => KeyboardAssist(
        type: asInt(row['type']),
        key: asString(row['key']),
        value: asString(row['value']),
        serialNo: asInt(row['serialNo']),
      );

  Map<String, Object?> toRow() => {
        'type': type,
        'key': key,
        'value': value,
        'serialNo': serialNo,
      };
}
