import 'package:legado_core/src/rules/source_rules.dart';
import 'package:test/test.dart';

void main() {
  group('SearchRule', () {
    test('fromJson 全字段', () {
      final rule = SearchRule.fromJson(const {
        'checkKeyWord': '校验',
        'bookList': 'class.book-list@li',
        'name': 'tag.a@text',
        'author': 'class.author@text',
        'kind': 'class.kind@text',
        'lastChapter': 'class.last@text',
        'intro': 'class.intro@text',
        'coverUrl': 'img@src',
        'bookUrl': 'tag.a@href',
        'wordCount': 'class.count@text',
      });
      expect(rule.checkKeyWord, '校验');
      expect(rule.bookList, 'class.book-list@li');
      expect(rule.name, 'tag.a@text');
      expect(rule.author, 'class.author@text');
      expect(rule.kind, 'class.kind@text');
      expect(rule.lastChapter, 'class.last@text');
      expect(rule.intro, 'class.intro@text');
      expect(rule.coverUrl, 'img@src');
      expect(rule.bookUrl, 'tag.a@href');
      expect(rule.wordCount, 'class.count@text');
    });

    test('缺失字段为 null，显式空串保留空串', () {
      final rule = SearchRule.fromJson(const {'name': '', 'author': null});
      expect(rule.name, '');
      expect(rule.author, isNull);
      expect(rule.bookList, isNull);
    });

    test('数字/布尔值宽松转字符串', () {
      final rule = SearchRule.fromJson(const {'name': 123, 'author': true});
      expect(rule.name, '123');
      expect(rule.author, 'true');
    });

    test('toJson 保留字段名', () {
      final json = const SearchRule(name: 'n', bookList: 'b').toJson();
      expect(json['name'], 'n');
      expect(json['bookList'], 'b');
      expect(json['author'], isNull);
    });

    test('toJsonWithoutNulls 去掉 null', () {
      final json = const SearchRule(name: 'n').toJsonWithoutNulls();
      expect(json.keys, ['name']);
    });
  });

  group('其余规则块', () {
    test('BookInfoRule', () {
      final r = BookInfoRule.fromJson(const {
        'init': 'class.info',
        'tocUrl': 'class.toc@href',
        'canReName': 'true',
        'downloadUrls': 'a@href',
      });
      expect(r.init, 'class.info');
      expect(r.tocUrl, 'class.toc@href');
      expect(r.canReName, 'true');
      expect(r.downloadUrls, 'a@href');
    });

    test('TocRule', () {
      final r = TocRule.fromJson(const {
        'chapterList': 'class.list@li',
        'chapterName': 'tag.a@text',
        'chapterUrl': 'tag.a@href',
        'formatJs': 'result',
        'isVolume': '--',
        'isVip': 'false',
        'nextTocUrl': 'class.next@href',
      });
      expect(r.chapterList, 'class.list@li');
      expect(r.chapterName, 'tag.a@text');
      expect(r.nextTocUrl, 'class.next@href');
      expect(r.isVip, 'false');
    });

    test('ContentRule', () {
      final r = ContentRule.fromJson(const {
        'content': 'id.content@html',
        'nextContentUrl': 'id.next@href',
        'webJs': 'window.scrollTo(0,1)',
        'sourceRegex': 'var c = "(.*?)"',
        'replaceRegex': '广告',
      });
      expect(r.content, 'id.content@html');
      expect(r.nextContentUrl, 'id.next@href');
      expect(r.webJs, isNotNull);
      expect(r.sourceRegex, contains('var c'));
      expect(r.replaceRegex, '广告');
    });

    test('ExploreRule 与 SearchRule 字段集一致（少 checkKeyWord）', () {
      final r = ExploreRule.fromJson(const {
        'bookList': 'li',
        'name': 'a@text',
        'bookUrl': 'a@href',
      });
      expect(r.bookList, 'li');
      expect(r.name, 'a@text');
      expect(r.bookUrl, 'a@href');
      expect(r.toJson().containsKey('checkKeyWord'), isFalse);
    });
  });

  group('UrlRule', () {
    test('searchUrl 裸字符串包成单条选项', () {
      final rule = UrlRule.fromJson(const {
        'searchUrl': 'https://a.com/search?q={{key}}',
      });
      expect(rule.hasSearch, isTrue);
      expect(rule.searchUrl.single.url, 'https://a.com/search?q={{key}}');
      expect(rule.searchUrlRaw, 'https://a.com/search?q={{key}}');
    });

    test('exploreUrl JSON 数组', () {
      final rule = UrlRule.fromJson(const {
        'exploreUrl':
            '[{"title":"玄幻","url":"/list/1.html"},{"title":"都市","url":"/list/2.html"}]',
      });
      expect(rule.exploreUrl, hasLength(2));
      expect(rule.exploreUrl.first.title, '玄幻');
      expect(rule.exploreUrl.last.url, '/list/2.html');
    });

    test('exploreUrl 容忍多余逗号', () {
      final rule = UrlRule.fromJson(const {
        'exploreUrl': '[{"title":"a","url":"/1",},{"title":"b","url":"/2"},]',
      });
      expect(rule.exploreUrl, hasLength(2));
    });

    test('exploreUrl 保留 style 字段', () {
      final rule = UrlRule.fromJson(const {
        'exploreUrl': '[{"title":"a","url":"/1","style":{"layout_flexBasisPercent":33}}]',
      });
      expect(rule.exploreUrl.single.style?['layout_flexBasisPercent'], 33);
    });

    test('空字符串视为无 URL 规则', () {
      final rule = UrlRule.fromJson(const {'searchUrl': '', 'exploreUrl': ''});
      expect(rule.hasSearch, isFalse);
      expect(rule.hasExplore, isFalse);
    });

    test('toJson 回写原始字符串', () {
      final rule = UrlRule.fromJson(const {'searchUrl': '/s?q={{key}}'});
      expect(rule.toJson()['searchUrl'], '/s?q={{key}}');
    });
  });

  group('UrlOption', () {
    test('useWebView 判定', () {
      expect(const UrlOption().useWebView, isFalse);
      expect(const UrlOption(webView: false).useWebView, isFalse);
      expect(const UrlOption(webView: 'false').useWebView, isFalse);
      expect(const UrlOption(webView: true).useWebView, isTrue);
      expect(const UrlOption(webView: 'true').useWebView, isTrue);
    });

    test('isPost 忽略大小写', () {
      expect(const UrlOption(method: 'post').isPost, isTrue);
      expect(const UrlOption(method: 'GET').isPost, isFalse);
    });

    test('retry / serverID 宽松转 int', () {
      final o = UrlOption.fromJson(const {'retry': '2', 'serverID': 7});
      expect(o.retry, 2);
      expect(o.serverID, 7);
    });
  });
}
