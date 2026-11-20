import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/store/database.dart';
import 'package:test/test.dart';

import 'store_test_support.dart';

void main() {
  late LegadoDatabase db;

  setUp(() {
    db = openTestDb();
    // 外键依赖：章节需要书、搜索结果需要书源。
    db.db.execute(
      "INSERT OR REPLACE INTO books (bookUrl, name, author) "
      "VALUES ('book-1', '测试书', '测试作者')",
    );
    db.db.execute(
      "INSERT OR REPLACE INTO book_sources (bookSourceUrl, bookSourceName, "
      "bookSourceType, lastUpdateTime, respondTime, weight) "
      "VALUES ('source-1', '测试源', 0, 0, 180000, 0)",
    );
  });

  tearDown(() => db.close());

  group('实体 round-trip', () {
    test('Book：全字段 + null 字段', () {
      final book = Book(
        bookUrl: 'book-1',
        tocUrl: 'https://a/toc',
        origin: 'https://a',
        originName: 'A源',
        name: '测试书',
        author: '测试作者',
        kind: '玄幻,都市',
        customTag: '我的最爱',
        coverUrl: 'https://a/cover.jpg',
        customCoverUrl: 'local://cover',
        intro: '简介',
        customIntro: '自定义简介',
        charset: 'GBK',
        type: BookType.text,
        group: 3,
        latestChapterTitle: '第2章',
        latestChapterTime: 1700000000000,
        lastCheckTime: 1700000000001,
        lastCheckCount: 2,
        totalChapterNum: 10,
        durChapterTitle: '第1章',
        durChapterIndex: 1,
        durChapterPos: 42,
        durChapterTime: 1700000000002,
        wordCount: '10万',
        canUpdate: false,
        order: 5,
        originOrder: 7,
        variable: '{"k":"v"}',
        readConfig: '{"reverseToc":true}',
        syncTime: 1700000000003,
      );
      final restored = Book.fromRow(insertAndRead(db, Book.tableBooks, book.toRow()));
      expect(restored.toRow(), equals(book.toRow()));
      expect(restored.kind, '玄幻,都市');
      expect(restored.canUpdate, isFalse);
    });

    test('Book：可空字段写 null 后读回仍为 null', () {
      final book = Book(bookUrl: 'book-null', name: '空书', author: '空作者');
      final restored = Book.fromRow(insertAndRead(db, Book.tableBooks, book.toRow()));
      expect(restored.kind, isNull);
      expect(restored.customTag, isNull);
      expect(restored.readConfig, isNull);
      expect(restored.toRow(), equals(book.toRow()));
    });

    test('BookChapter', () {
      final chapter = BookChapter(
        url: 'c1',
        title: '第一章',
        isVolume: true,
        baseUrl: 'https://a/',
        bookUrl: 'book-1',
        index: 3,
        isVip: true,
        isPay: false,
        resourceUrl: 'https://a/1.mp3',
        tag: '2024-01-01',
        wordCount: '3000',
        start: 100,
        end: 200,
        startFragmentId: 'f1',
        endFragmentId: 'f2',
        variable: '{"x":1}',
      );
      final restored =
          BookChapter.fromRow(insertAndRead(db, BookChapter.tableChapters, chapter.toRow()));
      expect(restored.toRow(), equals(chapter.toRow()));
      expect(restored.isVolume, isTrue);
      expect(restored.start, 100);
    });

    test('BookSource', () {
      final source = BookSource(
        bookSourceUrl: 'source-1',
        bookSourceName: '测试源',
        bookSourceGroup: '分组A,分组B',
        bookSourceType: BookSourceType.image,
        bookUrlPattern: 'https://a/book/\\d+',
        customOrder: 1,
        enabled: false,
        enabledExplore: false,
        jsLib: 'var a = 1;',
        enabledCookieJar: null,
        concurrentRate: '2/1000',
        header: '{"UA":"x"}',
        loginUrl: 'https://a/login',
        loginUi: '[{"name":"u"}]',
        loginCheckJs: 'true',
        coverDecodeJs: 'return url',
        bookSourceComment: '注释',
        variableComment: '变量说明',
        lastUpdateTime: 11,
        respondTime: 1234,
        weight: 9,
        exploreUrl: '发现::https://a',
        exploreScreen: '[]',
        ruleExplore: '{"bookList":"x"}',
        searchUrl: 'https://a/search?q=',
        ruleSearch: '{"bookList":"y"}',
        ruleBookInfo: '{"name":"z"}',
        ruleToc: '{"chapterList":"c"}',
        ruleContent: '{"content":"d"}',
        ruleReview: 'null',
      );
      final restored =
          BookSource.fromRow(insertAndRead(db, BookSource.tableBookSources, source.toRow()));
      expect(restored.toRow(), equals(source.toRow()));
      expect(restored.enabledCookieJar, isNull);
      expect(restored.ruleSearch, '{"bookList":"y"}');
    });

    test('BookGroup', () {
      final group = BookGroup(
        groupId: 4,
        groupName: '科幻',
        cover: 'local://g',
        order: 2,
        enableRefresh: false,
        show: false,
        bookSort: 3,
      );
      final restored =
          BookGroup.fromRow(insertAndRead(db, BookGroup.tableBookGroups, group.toRow()));
      expect(restored.toRow(), equals(group.toRow()));
    });

    test('Bookmark', () {
      final bookmark = Bookmark(
        time: 123,
        bookName: '测试书',
        bookAuthor: '测试作者',
        chapterIndex: 2,
        chapterPos: 11,
        chapterName: '第二章',
        bookText: '正文片段',
        content: '备注',
      );
      final restored =
          Bookmark.fromRow(insertAndRead(db, Bookmark.tableBookmarks, bookmark.toRow()));
      expect(restored.toRow(), equals(bookmark.toRow()));
    });

    test('ReadRecord', () {
      final record = ReadRecord(
        deviceId: 'dev',
        bookName: '测试书',
        readTime: 1000,
        lastRead: 2000,
      );
      final restored =
          ReadRecord.fromRow(insertAndRead(db, ReadRecord.tableReadRecord, record.toRow()));
      expect(restored.toRow(), equals(record.toRow()));
    });

    test('ReplaceRule（order <=> sortOrder 列名映射）', () {
      final rule = ReplaceRule(
        id: 9,
        name: '去广告',
        group: '净化',
        pattern: '广告.*',
        replacement: '',
        scope: '测试书',
        scopeTitle: true,
        scopeContent: false,
        excludeScope: '其他',
        isEnabled: false,
        isRegex: true,
        timeoutMillisecond: 1500,
        order: 6,
      );
      final restored = ReplaceRule.fromRow(
        insertAndRead(db, ReplaceRule.tableReplaceRules, rule.toRow()),
      );
      expect(restored.toRow(), equals(rule.toRow()));
      expect(restored.order, 6);
    });

    test('Cache', () {
      final cache = Cache(key: 'k', value: 'v', deadline: 999);
      final restored = Cache.fromRow(insertAndRead(db, Cache.tableCaches, cache.toRow()));
      expect(restored.toRow(), equals(cache.toRow()));
      final empty = Cache(key: 'k2');
      final restoredEmpty =
          Cache.fromRow(insertAndRead(db, Cache.tableCaches, empty.toRow()));
      expect(restoredEmpty.value, isNull);
    });

    test('SearchBook', () {
      final book = SearchBook(
        bookUrl: 'sb-1',
        origin: 'source-1',
        originName: '测试源',
        type: BookType.audio,
        name: '搜到的书',
        author: '作者',
        kind: '玄幻',
        coverUrl: 'https://a/c',
        intro: '简介',
        wordCount: '1万',
        latestChapterTitle: '第9章',
        tocUrl: 'https://a/toc',
        time: 456,
        variable: '{}',
        originOrder: 3,
        chapterWordCountText: '3000字',
        chapterWordCount: 3000,
        respondTime: 88,
      );
      final restored = SearchBook.fromRow(
        insertAndRead(db, SearchBook.tableSearchBooks, book.toRow()),
      );
      expect(restored.toRow(), equals(book.toRow()));
    });

    test('SearchKeyword', () {
      final keyword = SearchKeyword(word: '关键词', usage: 7, lastUseTime: 789);
      final restored = SearchKeyword.fromRow(
        insertAndRead(db, SearchKeyword.tableSearchKeywords, keyword.toRow()),
      );
      expect(restored.toRow(), equals(keyword.toRow()));
    });

    test('RssSource', () {
      final source = RssSource(
        sourceUrl: 'rss-1',
        sourceName: 'RSS源',
        sourceIcon: 'https://a/i.png',
        sourceGroup: '组1,组2',
        sourceComment: '注释',
        enabled: false,
        variableComment: '变量',
        jsLib: 'js',
        enabledCookieJar: null,
        concurrentRate: '1/1000',
        header: '{}',
        loginUrl: 'https://a/login',
        loginUi: '[]',
        loginCheckJs: 'true',
        coverDecodeJs: 'js',
        sortUrl: '分类',
        singleUrl: true,
        articleStyle: 2,
        ruleArticles: '规则',
        ruleNextPage: '下一页',
        ruleTitle: '标题',
        rulePubDate: '日期',
        ruleDescription: '描述',
        ruleImage: '图片',
        ruleLink: '链接',
        ruleContent: '正文',
        contentWhitelist: '白',
        contentBlacklist: '黑',
        shouldOverrideUrlLoading: 'js',
        style: '样式',
        enableJs: false,
        loadWithBaseUrl: false,
        injectJs: 'js',
        lastUpdateTime: 5,
        customOrder: 2,
      );
      final restored =
          RssSource.fromRow(insertAndRead(db, RssSource.tableRssSources, source.toRow()));
      expect(restored.toRow(), equals(source.toRow()));
    });

    test('RssArticle', () {
      final article = RssArticle(
        origin: 'rss-1',
        sort: '默认',
        title: '文章',
        order: 10,
        link: 'https://a/1',
        pubDate: '2024',
        description: '摘要',
        content: '内容',
        image: 'img',
        group: '分组',
        read: true,
        variable: '{}',
      );
      final restored = RssArticle.fromRow(
        insertAndRead(db, RssArticle.tableRssArticles, article.toRow()),
      );
      expect(restored.toRow(), equals(article.toRow()));
    });

    test('RssReadRecord', () {
      final record = RssReadRecord(
        record: 'https://a/1',
        title: '文章',
        readTime: 12,
        read: false,
      );
      final restored = RssReadRecord.fromRow(
        insertAndRead(db, RssReadRecord.tableRssReadRecords, record.toRow()),
      );
      expect(restored.toRow(), equals(record.toRow()));
      final minimal = RssReadRecord(record: 'r2');
      final restoredMinimal = RssReadRecord.fromRow(
        insertAndRead(db, RssReadRecord.tableRssReadRecords, minimal.toRow()),
      );
      expect(restoredMinimal.title, isNull);
      expect(restoredMinimal.readTime, isNull);
    });

    test('RssStar', () {
      final star = RssStar(
        origin: 'rss-1',
        sort: '默认',
        title: '收藏',
        starTime: 99,
        link: 'https://a/2',
        pubDate: '2024',
        description: 'd',
        content: 'c',
        image: 'i',
        group: '星标',
        variable: '{}',
      );
      final restored =
          RssStar.fromRow(insertAndRead(db, RssStar.tableRssStars, star.toRow()));
      expect(restored.toRow(), equals(star.toRow()));
    });

    test('DictRule', () {
      final rule = DictRule(
        name: '词典',
        urlRule: 'https://d/?w=',
        showRule: r'$..mean',
        enabled: false,
        sortNumber: 2,
      );
      final restored =
          DictRule.fromRow(insertAndRead(db, DictRule.tableDictRules, rule.toRow()));
      expect(restored.toRow(), equals(rule.toRow()));
    });

    test('HttpTTS', () {
      final tts = HttpTTS(
        id: 42,
        name: '引擎',
        url: 'https://tts/?t=',
        contentType: 'audio/mp3',
        concurrentRate: '3/1000',
        loginUrl: 'l',
        loginUi: 'u',
        header: 'h',
        jsLib: 'j',
        enabledCookieJar: true,
        loginCheckJs: 'c',
        lastUpdateTime: 7,
      );
      final restored =
          HttpTTS.fromRow(insertAndRead(db, HttpTTS.tableHttpTts, tts.toRow()));
      expect(restored.toRow(), equals(tts.toRow()));
      expect(restored.key, 'httpTts:42');
    });

    test('RuleSub', () {
      final sub = RuleSub(
        id: 77,
        name: '订阅',
        url: 'https://s/sub',
        type: 2,
        customOrder: 1,
        autoUpdate: true,
        update: 12345,
      );
      final restored =
          RuleSub.fromRow(insertAndRead(db, RuleSub.tableRuleSubs, sub.toRow()));
      expect(restored.toRow(), equals(sub.toRow()));
    });

    test('Server（枚举存 name 文本）', () {
      final server = Server(
        id: 5,
        name: 'WebDAV',
        type: ServerType.webdav,
        config: '{"url":"u"}',
        sortNumber: 1,
      );
      final restored =
          Server.fromRow(insertAndRead(db, Server.tableServers, server.toRow()));
      expect(restored.toRow(), equals(server.toRow()));
      expect(restored.type, 'WEBDAV');
    });

    test('TxtTocRule', () {
      final rule = TxtTocRule(
        id: 8,
        name: '正则',
        rule: '^第.+章',
        example: '第一章',
        serialNumber: 3,
        enable: false,
      );
      final restored =
          TxtTocRule.fromRow(insertAndRead(db, TxtTocRule.tableTxtTocRules, rule.toRow()));
      expect(restored.toRow(), equals(rule.toRow()));
    });

    test('Cookie', () {
      final cookie = Cookie(url: 'https://a', cookie: 'a=1; b=2');
      final restored =
          Cookie.fromRow(insertAndRead(db, Cookie.tableCookies, cookie.toRow()));
      expect(restored.toRow(), equals(cookie.toRow()));
    });

    test('KeyboardAssist（复合主键）', () {
      final assist = KeyboardAssist(type: 1, key: 'k', value: 'v', serialNo: 9);
      final restored = KeyboardAssist.fromRow(
        insertAndRead(db, KeyboardAssist.tableKeyboardAssists, assist.toRow()),
      );
      expect(restored.toRow(), equals(assist.toRow()));
    });
  });

  group('copyWith', () {
    test('Book.copyWith 能显式清空可空字段', () {
      final book = Book(bookUrl: 'b', name: 'n', author: 'a', kind: 'k');
      final cleared = book.copyWith(kind: null);
      expect(cleared.kind, isNull);
      expect(book.kind, 'k', reason: '不应修改原对象');
      expect(book.copyWith(name: 'n2').kind, 'k', reason: '未传的字段保持原值');
    });

    test('BookSource.copyWith 能显式清空规则 JSON', () {
      final source = BookSource(bookSourceUrl: 'u', ruleSearch: '{"a":1}');
      expect(source.copyWith(ruleSearch: null).ruleSearch, isNull);
      expect(source.copyWith(enabled: false).ruleSearch, '{"a":1}');
    });
  });
}
