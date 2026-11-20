import 'book.dart';
import 'row_utils.dart';

const Object _unsetSearch = Object();

/// 搜索结果书籍。
///
/// 与 [Book] 的差别：多了 `originOrder`（书源排序）、`chapterWordCount`（用于排序）、
/// `respondTime`（书源响应耗时），且 `origin` 外键指向 `book_sources`（删源自动删结果）。
class SearchBook {
  SearchBook({
    this.bookUrl = '',
    this.origin = '',
    this.originName = '',
    this.type = BookType.text,
    this.name = '',
    this.author = '',
    this.kind,
    this.coverUrl,
    this.intro,
    this.wordCount,
    this.latestChapterTitle,
    this.tocUrl = '',
    this.time = 0,
    this.variable,
    this.originOrder = 0,
    this.chapterWordCountText,
    this.chapterWordCount = -1,
    this.respondTime = -1,
  });

  static const String tableSearchBooks = 'searchBooks';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `searchBooks` (
  `bookUrl` TEXT NOT NULL,
  `origin` TEXT NOT NULL,
  `originName` TEXT NOT NULL,
  `type` INTEGER NOT NULL,
  `name` TEXT NOT NULL,
  `author` TEXT NOT NULL,
  `kind` TEXT,
  `coverUrl` TEXT,
  `intro` TEXT,
  `wordCount` TEXT,
  `latestChapterTitle` TEXT,
  `tocUrl` TEXT NOT NULL,
  `time` INTEGER NOT NULL,
  `variable` TEXT,
  `originOrder` INTEGER NOT NULL,
  `chapterWordCountText` TEXT,
  `chapterWordCount` INTEGER NOT NULL DEFAULT -1,
  `respondTime` INTEGER NOT NULL DEFAULT -1,
  PRIMARY KEY(`bookUrl`),
  FOREIGN KEY(`origin`) REFERENCES `book_sources`(`bookSourceUrl`) ON UPDATE NO ACTION ON DELETE CASCADE
)''';

  String bookUrl;
  String origin;
  String originName;
  int type;
  String name;
  String author;
  String? kind;
  String? coverUrl;
  String? intro;
  String? wordCount;
  String? latestChapterTitle;
  String tocUrl;
  int time;
  String? variable;
  int originOrder;
  String? chapterWordCountText;
  int chapterWordCount;
  int respondTime;

  factory SearchBook.fromRow(Map<String, Object?> row) => SearchBook(
        bookUrl: asString(row['bookUrl']),
        origin: asString(row['origin']),
        originName: asString(row['originName']),
        type: asInt(row['type'], BookType.text),
        name: asString(row['name']),
        author: asString(row['author']),
        kind: asStringOrNull(row['kind']),
        coverUrl: asStringOrNull(row['coverUrl']),
        intro: asStringOrNull(row['intro']),
        wordCount: asStringOrNull(row['wordCount']),
        latestChapterTitle: asStringOrNull(row['latestChapterTitle']),
        tocUrl: asString(row['tocUrl']),
        time: asInt(row['time']),
        variable: asStringOrNull(row['variable']),
        originOrder: asInt(row['originOrder']),
        chapterWordCountText: asStringOrNull(row['chapterWordCountText']),
        chapterWordCount: asInt(row['chapterWordCount'], -1),
        respondTime: asInt(row['respondTime'], -1),
      );

  Map<String, Object?> toRow() => {
        'bookUrl': bookUrl,
        'origin': origin,
        'originName': originName,
        'type': type,
        'name': name,
        'author': author,
        'kind': kind,
        'coverUrl': coverUrl,
        'intro': intro,
        'wordCount': wordCount,
        'latestChapterTitle': latestChapterTitle,
        'tocUrl': tocUrl,
        'time': time,
        'variable': variable,
        'originOrder': originOrder,
        'chapterWordCountText': chapterWordCountText,
        'chapterWordCount': chapterWordCount,
        'respondTime': respondTime,
      };

  /// 把搜索结果转成书架书籍（阅读层加入书架时调用）。
  Book toBook() => Book(
        name: name,
        author: author,
        kind: kind,
        bookUrl: bookUrl,
        origin: origin,
        originName: originName,
        type: type,
        wordCount: wordCount,
        latestChapterTitle: latestChapterTitle,
        coverUrl: coverUrl,
        intro: intro,
        tocUrl: tocUrl,
        originOrder: originOrder,
        variable: variable,
      );

  SearchBook copyWith({
    String? bookUrl,
    String? origin,
    String? originName,
    int? type,
    String? name,
    String? author,
    Object? kind = _unsetSearch,
    Object? coverUrl = _unsetSearch,
    Object? intro = _unsetSearch,
    Object? wordCount = _unsetSearch,
    Object? latestChapterTitle = _unsetSearch,
    String? tocUrl,
    int? time,
    Object? variable = _unsetSearch,
    int? originOrder,
    Object? chapterWordCountText = _unsetSearch,
    int? chapterWordCount,
    int? respondTime,
  }) =>
      SearchBook(
        bookUrl: bookUrl ?? this.bookUrl,
        origin: origin ?? this.origin,
        originName: originName ?? this.originName,
        type: type ?? this.type,
        name: name ?? this.name,
        author: author ?? this.author,
        kind: identical(kind, _unsetSearch) ? this.kind : kind as String?,
        coverUrl: identical(coverUrl, _unsetSearch) ? this.coverUrl : coverUrl as String?,
        intro: identical(intro, _unsetSearch) ? this.intro : intro as String?,
        wordCount: identical(wordCount, _unsetSearch) ? this.wordCount : wordCount as String?,
        latestChapterTitle: identical(latestChapterTitle, _unsetSearch)
            ? this.latestChapterTitle
            : latestChapterTitle as String?,
        tocUrl: tocUrl ?? this.tocUrl,
        time: time ?? this.time,
        variable: identical(variable, _unsetSearch) ? this.variable : variable as String?,
        originOrder: originOrder ?? this.originOrder,
        chapterWordCountText: identical(chapterWordCountText, _unsetSearch)
            ? this.chapterWordCountText
            : chapterWordCountText as String?,
        chapterWordCount: chapterWordCount ?? this.chapterWordCount,
        respondTime: respondTime ?? this.respondTime,
      );

  @override
  bool operator ==(Object other) => other is SearchBook && other.bookUrl == bookUrl;

  @override
  int get hashCode => bookUrl.hashCode;
}

/// 搜索关键词历史。
class SearchKeyword {
  SearchKeyword({
    this.word = '',
    this.usage = 1,
    this.lastUseTime = 0,
  });

  static const String tableSearchKeywords = 'search_keywords';

  static const String createSql = '''
CREATE TABLE IF NOT EXISTS `search_keywords` (
  `word` TEXT NOT NULL,
  `usage` INTEGER NOT NULL,
  `lastUseTime` INTEGER NOT NULL,
  PRIMARY KEY(`word`)
)''';

  String word;
  int usage;
  int lastUseTime;

  factory SearchKeyword.fromRow(Map<String, Object?> row) => SearchKeyword(
        word: asString(row['word']),
        usage: asInt(row['usage'], 1),
        lastUseTime: asInt(row['lastUseTime']),
      );

  Map<String, Object?> toRow() => {
        'word': word,
        'usage': usage,
        'lastUseTime': lastUseTime,
      };
}
