import 'row_utils.dart';

/// 书籍类型位域，对应 Kotlin `BookType`。
///
/// 用二进制位而不是枚举：一本书可以同时是「文本 + 本地」，
/// 且 `books.type & :type > 0` 这类查询可以直接走索引。
abstract final class BookType {
  /// 文本（8）
  static const int text = 0x8;

  /// 更新失败（16）
  static const int updateError = 0x10;

  /// 音频（32）
  static const int audio = 0x20;

  /// 图片（64）
  static const int image = 0x40;

  /// 只提供下载服务的网站（128）
  static const int webFile = 0x80;

  /// 本地（256）
  static const int local = 0x100;

  /// 压缩包解压（512）
  static const int archive = 0x200;

  /// 未正式加入书架的临时书籍（1024）
  static const int notShelf = 0x400;

  /// 可从书源转换的书籍类型。
  static const int allBookType = text | image | audio | webFile;

  /// 含本地书籍的全部类型。
  static const int allBookTypeLocal = allBookType | local;

  /// 本地书籍书源标志。
  static const String localTag = 'loc_book';

  /// WebDAV 书籍书源前缀。
  static const String webDavTag = 'webDav::';
}

/// 书源类型，对应 Kotlin `BookSourceType`。
abstract final class BookSourceType {
  static const int text = 0;
  static const int audio = 1;
  static const int image = 2;
  static const int file = 3;
}

const Object _unset = Object();

/// 书籍（书架条目）。
///
/// 表名 `books`，主键 `bookUrl`，`(name, author)` 唯一索引。
/// 注意 `readConfig` 在 Kotlin 里是 `ReadConfig` 对象，由 TypeConverter 转成 JSON 存 TEXT；
/// Dart 侧先保留原始 JSON 字符串，交给规则/阅读层按需解析，避免领域层耦合 UI 配置结构。
class Book {
  Book({
    this.bookUrl = '',
    this.tocUrl = '',
    this.origin = BookType.localTag,
    this.originName = '',
    this.name = '',
    this.author = '',
    this.kind,
    this.customTag,
    this.coverUrl,
    this.customCoverUrl,
    this.intro,
    this.customIntro,
    this.charset,
    this.type = 0,
    this.group = 0,
    this.latestChapterTitle,
    this.latestChapterTime = 0,
    this.lastCheckTime = 0,
    this.lastCheckCount = 0,
    this.totalChapterNum = 0,
    this.durChapterTitle,
    this.durChapterIndex = 0,
    this.durChapterPos = 0,
    this.durChapterTime = 0,
    this.wordCount,
    this.canUpdate = true,
    this.order = 0,
    this.originOrder = 0,
    this.variable,
    this.readConfig,
    this.syncTime = 0,
  });

  static const String tableBooks = 'books';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `books` (
  `bookUrl` TEXT NOT NULL DEFAULT '',
  `tocUrl` TEXT NOT NULL DEFAULT '',
  `origin` TEXT NOT NULL DEFAULT 'loc_book',
  `originName` TEXT NOT NULL DEFAULT '',
  `name` TEXT NOT NULL DEFAULT '',
  `author` TEXT NOT NULL DEFAULT '',
  `kind` TEXT,
  `customTag` TEXT,
  `coverUrl` TEXT,
  `customCoverUrl` TEXT,
  `intro` TEXT,
  `customIntro` TEXT,
  `charset` TEXT,
  `type` INTEGER NOT NULL DEFAULT 0,
  `group` INTEGER NOT NULL DEFAULT 0,
  `latestChapterTitle` TEXT,
  `latestChapterTime` INTEGER NOT NULL DEFAULT 0,
  `lastCheckTime` INTEGER NOT NULL DEFAULT 0,
  `lastCheckCount` INTEGER NOT NULL DEFAULT 0,
  `totalChapterNum` INTEGER NOT NULL DEFAULT 0,
  `durChapterTitle` TEXT,
  `durChapterIndex` INTEGER NOT NULL DEFAULT 0,
  `durChapterPos` INTEGER NOT NULL DEFAULT 0,
  `durChapterTime` INTEGER NOT NULL DEFAULT 0,
  `wordCount` TEXT,
  `canUpdate` INTEGER NOT NULL DEFAULT 1,
  `order` INTEGER NOT NULL DEFAULT 0,
  `originOrder` INTEGER NOT NULL DEFAULT 0,
  `variable` TEXT,
  `readConfig` TEXT,
  `syncTime` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`bookUrl`)
)''';

  /// 详情页 Url（本地书籍存完整文件路径）。
  String bookUrl;

  /// 目录页 Url。
  String tocUrl;

  /// 书源 Url（本地书籍为 [BookType.localTag]）。
  String origin;

  /// 书源名称或本地文件名。
  String originName;

  String name;

  String author;

  /// 书源给的分类。
  String? kind;

  /// 用户自定义分类。
  String? customTag;

  String? coverUrl;

  String? customCoverUrl;

  String? intro;

  String? customIntro;

  /// 自定义字符集（仅本地书籍）。
  String? charset;

  /// 位域，见 [BookType]。
  int type;

  /// 自定义分组位域。
  int group;

  String? latestChapterTitle;

  int latestChapterTime;

  int lastCheckTime;

  int lastCheckCount;

  int totalChapterNum;

  String? durChapterTitle;

  int durChapterIndex;

  /// 当前章节内阅读位置（首行字符下标）。
  int durChapterPos;

  int durChapterTime;

  String? wordCount;

  bool canUpdate;

  int order;

  int originOrder;

  String? variable;

  /// 阅读设置 JSON（对应 Kotlin `ReadConfig`）。
  String? readConfig;

  int syncTime;

  int get lastChapterIndex => totalChapterNum - 1;

  String get displayCover =>
      (customCoverUrl == null || customCoverUrl!.isEmpty)
          ? (coverUrl ?? '')
          : customCoverUrl!;

  String get displayIntro =>
      (customIntro == null || customIntro!.isEmpty) ? (intro ?? '') : customIntro!;

  bool get isLocal => type & BookType.local > 0;

  factory Book.fromRow(Map<String, Object?> row) => Book(
        bookUrl: asString(row['bookUrl']),
        tocUrl: asString(row['tocUrl']),
        origin: asString(row['origin'], BookType.localTag),
        originName: asString(row['originName']),
        name: asString(row['name']),
        author: asString(row['author']),
        kind: asStringOrNull(row['kind']),
        customTag: asStringOrNull(row['customTag']),
        coverUrl: asStringOrNull(row['coverUrl']),
        customCoverUrl: asStringOrNull(row['customCoverUrl']),
        intro: asStringOrNull(row['intro']),
        customIntro: asStringOrNull(row['customIntro']),
        charset: asStringOrNull(row['charset']),
        type: asInt(row['type']),
        group: asInt(row['group']),
        latestChapterTitle: asStringOrNull(row['latestChapterTitle']),
        latestChapterTime: asInt(row['latestChapterTime']),
        lastCheckTime: asInt(row['lastCheckTime']),
        lastCheckCount: asInt(row['lastCheckCount']),
        totalChapterNum: asInt(row['totalChapterNum']),
        durChapterTitle: asStringOrNull(row['durChapterTitle']),
        durChapterIndex: asInt(row['durChapterIndex']),
        durChapterPos: asInt(row['durChapterPos']),
        durChapterTime: asInt(row['durChapterTime']),
        wordCount: asStringOrNull(row['wordCount']),
        canUpdate: asBool(row['canUpdate'], fallback: true),
        order: asInt(row['order']),
        originOrder: asInt(row['originOrder']),
        variable: asStringOrNull(row['variable']),
        readConfig: asStringOrNull(row['readConfig']),
        syncTime: asInt(row['syncTime']),
      );

  Map<String, Object?> toRow() => {
        'bookUrl': bookUrl,
        'tocUrl': tocUrl,
        'origin': origin,
        'originName': originName,
        'name': name,
        'author': author,
        'kind': kind,
        'customTag': customTag,
        'coverUrl': coverUrl,
        'customCoverUrl': customCoverUrl,
        'intro': intro,
        'customIntro': customIntro,
        'charset': charset,
        'type': type,
        'group': group,
        'latestChapterTitle': latestChapterTitle,
        'latestChapterTime': latestChapterTime,
        'lastCheckTime': lastCheckTime,
        'lastCheckCount': lastCheckCount,
        'totalChapterNum': totalChapterNum,
        'durChapterTitle': durChapterTitle,
        'durChapterIndex': durChapterIndex,
        'durChapterPos': durChapterPos,
        'durChapterTime': durChapterTime,
        'wordCount': wordCount,
        'canUpdate': boolToInt(canUpdate),
        'order': order,
        'originOrder': originOrder,
        'variable': variable,
        'readConfig': readConfig,
        'syncTime': syncTime,
      };

  Book copyWith({
    String? bookUrl,
    String? tocUrl,
    String? origin,
    String? originName,
    String? name,
    String? author,
    Object? kind = _unset,
    Object? customTag = _unset,
    Object? coverUrl = _unset,
    Object? customCoverUrl = _unset,
    Object? intro = _unset,
    Object? customIntro = _unset,
    Object? charset = _unset,
    int? type,
    int? group,
    Object? latestChapterTitle = _unset,
    int? latestChapterTime,
    int? lastCheckTime,
    int? lastCheckCount,
    int? totalChapterNum,
    Object? durChapterTitle = _unset,
    int? durChapterIndex,
    int? durChapterPos,
    int? durChapterTime,
    Object? wordCount = _unset,
    bool? canUpdate,
    int? order,
    int? originOrder,
    Object? variable = _unset,
    Object? readConfig = _unset,
    int? syncTime,
  }) =>
      Book(
        bookUrl: bookUrl ?? this.bookUrl,
        tocUrl: tocUrl ?? this.tocUrl,
        origin: origin ?? this.origin,
        originName: originName ?? this.originName,
        name: name ?? this.name,
        author: author ?? this.author,
        kind: identical(kind, _unset) ? this.kind : kind as String?,
        customTag: identical(customTag, _unset) ? this.customTag : customTag as String?,
        coverUrl: identical(coverUrl, _unset) ? this.coverUrl : coverUrl as String?,
        customCoverUrl: identical(customCoverUrl, _unset)
            ? this.customCoverUrl
            : customCoverUrl as String?,
        intro: identical(intro, _unset) ? this.intro : intro as String?,
        customIntro: identical(customIntro, _unset)
            ? this.customIntro
            : customIntro as String?,
        charset: identical(charset, _unset) ? this.charset : charset as String?,
        type: type ?? this.type,
        group: group ?? this.group,
        latestChapterTitle: identical(latestChapterTitle, _unset)
            ? this.latestChapterTitle
            : latestChapterTitle as String?,
        latestChapterTime: latestChapterTime ?? this.latestChapterTime,
        lastCheckTime: lastCheckTime ?? this.lastCheckTime,
        lastCheckCount: lastCheckCount ?? this.lastCheckCount,
        totalChapterNum: totalChapterNum ?? this.totalChapterNum,
        durChapterTitle: identical(durChapterTitle, _unset)
            ? this.durChapterTitle
            : durChapterTitle as String?,
        durChapterIndex: durChapterIndex ?? this.durChapterIndex,
        durChapterPos: durChapterPos ?? this.durChapterPos,
        durChapterTime: durChapterTime ?? this.durChapterTime,
        wordCount: identical(wordCount, _unset) ? this.wordCount : wordCount as String?,
        canUpdate: canUpdate ?? this.canUpdate,
        order: order ?? this.order,
        originOrder: originOrder ?? this.originOrder,
        variable: identical(variable, _unset) ? this.variable : variable as String?,
        readConfig: identical(readConfig, _unset) ? this.readConfig : readConfig as String?,
        syncTime: syncTime ?? this.syncTime,
      );

  @override
  bool operator ==(Object other) => other is Book && other.bookUrl == bookUrl;

  @override
  int get hashCode => bookUrl.hashCode;
}

/// 章节。
///
/// 复合主键 `(url, bookUrl)`；`bookUrl` 外键级联删除，删书自动删章。
class BookChapter {
  BookChapter({
    this.url = '',
    this.title = '',
    this.isVolume = false,
    this.baseUrl = '',
    this.bookUrl = '',
    this.index = 0,
    this.isVip = false,
    this.isPay = false,
    this.resourceUrl,
    this.tag,
    this.wordCount,
    this.start,
    this.end,
    this.startFragmentId,
    this.endFragmentId,
    this.variable,
  });

  static const String tableChapters = 'chapters';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `chapters` (
  `url` TEXT NOT NULL,
  `title` TEXT NOT NULL,
  `isVolume` INTEGER NOT NULL,
  `baseUrl` TEXT NOT NULL,
  `bookUrl` TEXT NOT NULL,
  `index` INTEGER NOT NULL,
  `isVip` INTEGER NOT NULL,
  `isPay` INTEGER NOT NULL,
  `resourceUrl` TEXT,
  `tag` TEXT,
  `wordCount` TEXT,
  `start` INTEGER,
  `end` INTEGER,
  `startFragmentId` TEXT,
  `endFragmentId` TEXT,
  `variable` TEXT,
  PRIMARY KEY(`url`, `bookUrl`),
  FOREIGN KEY(`bookUrl`) REFERENCES `books`(`bookUrl`) ON UPDATE NO ACTION ON DELETE CASCADE
)''';

  String url;
  String title;

  /// 是否是卷名。
  bool isVolume;

  /// 拼接相对 URL 用。
  String baseUrl;
  String bookUrl;

  /// 章节序号。
  int index;
  bool isVip;
  bool isPay;

  /// 音频真实 URL。
  String? resourceUrl;

  /// 更新时间或其他附加信息。
  String? tag;
  String? wordCount;

  /// 章节在文件中的起始位置（本地书）。
  int? start;
  int? end;
  String? startFragmentId;
  String? endFragmentId;
  String? variable;

  factory BookChapter.fromRow(Map<String, Object?> row) => BookChapter(
        url: asString(row['url']),
        title: asString(row['title']),
        isVolume: asBool(row['isVolume']),
        baseUrl: asString(row['baseUrl']),
        bookUrl: asString(row['bookUrl']),
        index: asInt(row['index']),
        isVip: asBool(row['isVip']),
        isPay: asBool(row['isPay']),
        resourceUrl: asStringOrNull(row['resourceUrl']),
        tag: asStringOrNull(row['tag']),
        wordCount: asStringOrNull(row['wordCount']),
        start: asIntOrNull(row['start']),
        end: asIntOrNull(row['end']),
        startFragmentId: asStringOrNull(row['startFragmentId']),
        endFragmentId: asStringOrNull(row['endFragmentId']),
        variable: asStringOrNull(row['variable']),
      );

  Map<String, Object?> toRow() => {
        'url': url,
        'title': title,
        'isVolume': boolToInt(isVolume),
        'baseUrl': baseUrl,
        'bookUrl': bookUrl,
        'index': index,
        'isVip': boolToInt(isVip),
        'isPay': boolToInt(isPay),
        'resourceUrl': resourceUrl,
        'tag': tag,
        'wordCount': wordCount,
        'start': start,
        'end': end,
        'startFragmentId': startFragmentId,
        'endFragmentId': endFragmentId,
        'variable': variable,
      };

  BookChapter copyWith({
    String? url,
    String? title,
    bool? isVolume,
    String? baseUrl,
    String? bookUrl,
    int? index,
    bool? isVip,
    bool? isPay,
    Object? resourceUrl = _unset,
    Object? tag = _unset,
    Object? wordCount = _unset,
    Object? start = _unset,
    Object? end = _unset,
    Object? startFragmentId = _unset,
    Object? endFragmentId = _unset,
    Object? variable = _unset,
  }) =>
      BookChapter(
        url: url ?? this.url,
        title: title ?? this.title,
        isVolume: isVolume ?? this.isVolume,
        baseUrl: baseUrl ?? this.baseUrl,
        bookUrl: bookUrl ?? this.bookUrl,
        index: index ?? this.index,
        isVip: isVip ?? this.isVip,
        isPay: isPay ?? this.isPay,
        resourceUrl:
            identical(resourceUrl, _unset) ? this.resourceUrl : resourceUrl as String?,
        tag: identical(tag, _unset) ? this.tag : tag as String?,
        wordCount: identical(wordCount, _unset) ? this.wordCount : wordCount as String?,
        start: identical(start, _unset) ? this.start : start as int?,
        end: identical(end, _unset) ? this.end : end as int?,
        startFragmentId: identical(startFragmentId, _unset)
            ? this.startFragmentId
            : startFragmentId as String?,
        endFragmentId:
            identical(endFragmentId, _unset) ? this.endFragmentId : endFragmentId as String?,
        variable: identical(variable, _unset) ? this.variable : variable as String?,
      );

  String primaryStr() => bookUrl + url;

  @override
  bool operator ==(Object other) => other is BookChapter && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// 书架分组。
class BookGroup {
  BookGroup({
    this.groupId = 1,
    this.groupName = '',
    this.cover,
    this.order = 0,
    this.enableRefresh = true,
    this.show = true,
    this.bookSort = -1,
  });

  static const String tableBookGroups = 'book_groups';

  /// 分组位域里保留给「根分组」的虚拟 id。
  static const int idRoot = -100;
  static const int idAll = -1;
  static const int idLocal = -2;
  static const int idAudio = -3;
  static const int idNetNone = -4;
  static const int idLocalNone = -5;
  static const int idError = -11;

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `book_groups` (
  `groupId` INTEGER NOT NULL,
  `groupName` TEXT NOT NULL,
  `cover` TEXT,
  `order` INTEGER NOT NULL,
  `enableRefresh` INTEGER NOT NULL DEFAULT 1,
  `show` INTEGER NOT NULL DEFAULT 1,
  `bookSort` INTEGER NOT NULL DEFAULT -1,
  PRIMARY KEY(`groupId`)
)''';

  int groupId;
  String groupName;
  String? cover;
  int order;
  bool enableRefresh;
  bool show;
  int bookSort;

  factory BookGroup.fromRow(Map<String, Object?> row) => BookGroup(
        groupId: asInt(row['groupId'], 1),
        groupName: asString(row['groupName']),
        cover: asStringOrNull(row['cover']),
        order: asInt(row['order']),
        enableRefresh: asBool(row['enableRefresh'], fallback: true),
        show: asBool(row['show'], fallback: true),
        bookSort: asInt(row['bookSort'], -1),
      );

  Map<String, Object?> toRow() => {
        'groupId': groupId,
        'groupName': groupName,
        'cover': cover,
        'order': order,
        'enableRefresh': boolToInt(enableRefresh),
        'show': boolToInt(show),
        'bookSort': bookSort,
      };

  BookGroup copyWith({
    int? groupId,
    String? groupName,
    Object? cover = _unset,
    int? order,
    bool? enableRefresh,
    bool? show,
    int? bookSort,
  }) =>
      BookGroup(
        groupId: groupId ?? this.groupId,
        groupName: groupName ?? this.groupName,
        cover: identical(cover, _unset) ? this.cover : cover as String?,
        order: order ?? this.order,
        enableRefresh: enableRefresh ?? this.enableRefresh,
        show: show ?? this.show,
        bookSort: bookSort ?? this.bookSort,
      );
}

/// 书签。
class Bookmark {
  Bookmark({
    this.time = 0,
    this.bookName = '',
    this.bookAuthor = '',
    this.chapterIndex = 0,
    this.chapterPos = 0,
    this.chapterName = '',
    this.bookText = '',
    this.content = '',
  });

  static const String tableBookmarks = 'bookmarks';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `bookmarks` (
  `time` INTEGER NOT NULL,
  `bookName` TEXT NOT NULL,
  `bookAuthor` TEXT NOT NULL,
  `chapterIndex` INTEGER NOT NULL,
  `chapterPos` INTEGER NOT NULL,
  `chapterName` TEXT NOT NULL,
  `bookText` TEXT NOT NULL,
  `content` TEXT NOT NULL,
  PRIMARY KEY(`time`)
)''';

  int time;
  String bookName;
  String bookAuthor;
  int chapterIndex;
  int chapterPos;
  String chapterName;
  String bookText;
  String content;

  factory Bookmark.fromRow(Map<String, Object?> row) => Bookmark(
        time: asInt(row['time']),
        bookName: asString(row['bookName']),
        bookAuthor: asString(row['bookAuthor']),
        chapterIndex: asInt(row['chapterIndex']),
        chapterPos: asInt(row['chapterPos']),
        chapterName: asString(row['chapterName']),
        bookText: asString(row['bookText']),
        content: asString(row['content']),
      );

  Map<String, Object?> toRow() => {
        'time': time,
        'bookName': bookName,
        'bookAuthor': bookAuthor,
        'chapterIndex': chapterIndex,
        'chapterPos': chapterPos,
        'chapterName': chapterName,
        'bookText': bookText,
        'content': content,
      };
}

/// 阅读时长记录，主键 `(deviceId, bookName)`。
class ReadRecord {
  ReadRecord({
    this.deviceId = '',
    this.bookName = '',
    this.readTime = 0,
    this.lastRead = 0,
  });

  static const String tableReadRecord = 'readRecord';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `readRecord` (
  `deviceId` TEXT NOT NULL,
  `bookName` TEXT NOT NULL,
  `readTime` INTEGER NOT NULL DEFAULT 0,
  `lastRead` INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(`deviceId`, `bookName`)
)''';

  String deviceId;
  String bookName;
  int readTime;
  int lastRead;

  factory ReadRecord.fromRow(Map<String, Object?> row) => ReadRecord(
        deviceId: asString(row['deviceId']),
        bookName: asString(row['bookName']),
        readTime: asInt(row['readTime']),
        lastRead: asInt(row['lastRead']),
      );

  Map<String, Object?> toRow() => {
        'deviceId': deviceId,
        'bookName': bookName,
        'readTime': readTime,
        'lastRead': lastRead,
      };
}

/// 阅读统计的聚合结果（`group by bookName`），不是表。
class ReadRecordShow {
  ReadRecordShow({
    required this.bookName,
    required this.readTime,
    required this.lastRead,
  });

  final String bookName;
  final int readTime;
  final int lastRead;

  factory ReadRecordShow.fromRow(Map<String, Object?> row) => ReadRecordShow(
        bookName: asString(row['bookName']),
        readTime: asInt(row['readTime']),
        lastRead: asInt(row['lastRead']),
      );
}

/// 书籍进度快照（DTO，不是表）。
class BookProgress {
  BookProgress({
    required this.name,
    required this.author,
    required this.durChapterIndex,
    required this.durChapterPos,
    required this.durChapterTime,
    this.durChapterTitle,
  });

  factory BookProgress.fromBook(Book book) => BookProgress(
        name: book.name,
        author: book.author,
        durChapterIndex: book.durChapterIndex,
        durChapterPos: book.durChapterPos,
        durChapterTime: book.durChapterTime,
        durChapterTitle: book.durChapterTitle,
      );

  final String name;
  final String author;
  final int durChapterIndex;
  final int durChapterPos;
  final int durChapterTime;
  final String? durChapterTitle;

  Map<String, Object?> toJson() => {
        'name': name,
        'author': author,
        'durChapterIndex': durChapterIndex,
        'durChapterPos': durChapterPos,
        'durChapterTime': durChapterTime,
        'durChapterTitle': durChapterTitle,
      };
}

/// 段评锚点（DTO，Kotlin 侧无 `@Entity`，不建表）。
class BookChapterReview {
  BookChapterReview({
    this.bookId = 0,
    this.chapterId = 0,
    this.summaryUrl = '',
  });

  int bookId;
  int chapterId;
  String summaryUrl;
}
