import 'package:legado_core/src/rules/html_rule.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

HtmlRule rule([String baseUrl = 'https://example.com/']) =>
    HtmlRule(sampleHtml, baseUrl: baseUrl);

void main() {
  group('文本取值', () {
    test('@text 做空白归一化（jsoup Element.text）', () {
      expect(rule().getStringList('li@text'), [
        '书名一 作者甲',
        '书名二 作者乙',
        '书名三 作者丙',
        '书名四 作者丁',
      ]);
    });

    test('块级元素之间补空格，行内元素之间不补', () {
      expect(rule().getString('div#blocks@text'), '块一 块二');
      expect(rule().getString('div#inline@text'), '前中后');
    });

    test('@ownText 只取直接文本子节点', () {
      expect(rule().getString('div#own@ownText'), '自己');
      expect(rule().getString('div#own@text'), '自己 子');
    });

    test('@textNodes 返回直接文本节点', () {
      final el = rule().getElements('li:eq(0) a').first;
      expect(HtmlRule(el).getString('textNodes'), '书名一');
      expect(rule().getString('div#own@textNodes'), '自己');
    });

    test('@html 去掉 script/style 后返回 outerHtml', () {
      final html = rule().getString('li[0]@html')!;
      expect(html, contains('href="/book/1"'));
      expect(html, contains('作者甲'));
    });

    test('@all 返回 outerHtml', () {
      expect(rule().getString('ul#list@all'), startsWith('<ul id="list"'));
    });

    test('空规则返回 null', () {
      expect(rule().getString(''), isNull);
      expect(rule().getStringList(''), isEmpty);
    });
  });

  group('属性取值', () {
    test('@href 取属性', () {
      expect(rule().getStringList('li a@href'), [
        '/book/1',
        '/book/2',
        '/book/3',
        '/book/4',
      ]);
    });

    test('属性值去重（jsoup getResultLast 行为）', () {
      final r = HtmlRule(
        '<html><body><a href="/x">1</a><a href="/x">2</a></body></html>',
      );
      expect(r.getStringList('a@href'), ['/x']);
    });

    test('@abs:href 绝对化', () {
      expect(rule().getString('li:eq(0) a@abs:href'),
          'https://example.com/book/1');
    });

    test('data-* 属性', () {
      expect(rule().getString('img@data-src'), '//cdn.example.com/c.jpg');
    });

    test('单段规则是属性名（chapterUrl: "href" 写法）', () {
      final el = rule().getElements('li:eq(0) a').first;
      expect(HtmlRule(el).getString('href'), '/book/1');
      expect(HtmlRule(el).getString('title'), '一号');
      expect(HtmlRule(el).getString('text'), '书名一');
    });
  });

  group('位置与索引', () {
    test('[n] 单索引', () {
      expect(rule().getStringList('li[0]@text'), ['书名一 作者甲']);
      expect(rule().getStringList('li[2]@text'), ['书名三 作者丙']);
    });

    test('[-1] 负索引取末尾', () {
      expect(rule().getStringList('li[-1]@text'), ['书名四 作者丁']);
    });

    test('[a,b] 多索引按书写顺序', () {
      expect(rule().getStringList('li[2,0]@text'),
          ['书名三 作者丙', '书名一 作者甲']);
    });

    test('[start:end] 区间（含两端）', () {
      expect(rule().getStringList('li[1:3]@text'),
          ['书名二 作者乙', '书名三 作者丙', '书名四 作者丁']);
    });

    test('[!n] 排除', () {
      expect(rule().getStringList('li[!0]@text'),
          ['书名二 作者乙', '书名三 作者丙', '书名四 作者丁']);
    });

    test('旧写法 !0:2 排除多个', () {
      expect(rule().getStringList('li!0:2@text'), ['书名二 作者乙', '书名四 作者丁']);
    });

    test('旧写法 .0 选择', () {
      expect(rule().getStringList('li.1@text'), ['书名二 作者乙']);
    });

    test('反向区间 [-1:0] 让列表反向', () {
      expect(rule().getStringList('li[-1:0]@text'), [
        '书名四 作者丁',
        '书名三 作者丙',
        '书名二 作者乙',
        '书名一 作者甲',
      ]);
    });
  });

  group('组合符', () {
    test('&& 顺序拼接', () {
      expect(rule().getStringList('li[0]@text && li[1]@text'),
          ['书名一 作者甲', '书名二 作者乙']);
    });

    test('|| 取第一个非空结果', () {
      expect(rule().getStringList('li.none@text || li[0]@text'), ['书名一 作者甲']);
    });

    test('%% 交错合并（以第 1 段长度为界）', () {
      expect(
        rule().getStringList('li[0,1]@text %% li[2,3]@text'),
        ['书名一 作者甲', '书名三 作者丙', '书名二 作者乙', '书名四 作者丁'],
      );
    });

    test('%% 较短首段不会被拉长', () {
      expect(rule().getStringList('li[0]@text %% li[0,1]@text'),
          ['书名一 作者甲', '书名一 作者甲']);
    });
  });

  group('选择器语法', () {
    test('类选择器', () {
      expect(rule().getStringList('li.odd a@text'), ['书名一', '书名三']);
    });

    test('后代选择器', () {
      expect(rule().getStringList('ul#list li span@text'), [
        '作者甲',
        '作者乙',
        '作者丙',
        '作者丁',
      ]);
    });

    test('多选择器并集（逗号）按文档顺序', () {
      expect(rule().getStringList('li a, #next'),
          ['书名一', '书名二', '书名三', '书名四', '下一页']);
    });

    test('属性前缀/后缀/包含选择器（值为裸串）', () {
      expect(rule().getStringList('a[href^=/book]@href'), hasLength(4));
      expect(rule().getStringList(r'a[href$=2]@text'), ['书名二', '下一页']);
      expect(rule().getStringList('a[href*=/book/2]@text'), ['书名二']);
    });

    test('属性~= 词匹配', () {
      expect(rule().getStringList('a[title~=二号]@text'), ['书名二']);
    });

    test('class./tag./id./text. 前缀', () {
      expect(rule().getStringList('class.item@text'), hasLength(4));
      expect(rule().getStringList('tag.a@href'), hasLength(5));
      expect(rule().getString('id.next@text'), '下一页');
      expect(rule().getString('text.下一页'), '下一页');
    });

    test(':eq/:lt/:gt 按兄弟下标过滤', () {
      expect(rule().getStringList('li:eq(1) a@text'), ['书名二']);
      expect(rule().getStringList('li:lt(2) a@text'), ['书名一', '书名二']);
      expect(rule().getStringList('li:gt(1) a@text'), ['书名三', '书名四']);
    });

    test(':first / :last', () {
      expect(rule().getStringList('li.odd:first a@text'), ['书名一']);
      expect(rule().getStringList('li:last a@text'), ['书名四']);
    });

    test(':contains 文本包含', () {
      expect(rule().getStringList('li:contains(书名三) a@text'), ['书名三']);
    });

    test(':has 后代存在', () {
      expect(rule().getStringList('li:has(span.author) a@text'), hasLength(4));
    });

    test(':not 排除', () {
      expect(rule().getStringList('li:not(.odd) a@text'), ['书名二', '书名四']);
    });

    test('@CSS: 前缀强制按 CSS 解析', () {
      expect(rule().getStringList('@CSS:li a@href'), hasLength(4));
    });
  });

  group('元素列表', () {
    test('getElements 返回元素列表', () {
      final elements = rule().getElements('li');
      expect(elements, hasLength(4));
      expect(HtmlRule(elements[0]).getString('a@href'), '/book/1');
    });

    test('getElements 支持 && 组合', () {
      expect(rule().getElements('li[!0]'), hasLength(3));
    });
  });

  group('边界情况', () {
    test('旧写法负索引 li.-1', () {
      expect(rule().getStringList('li.-1@text'), ['书名四 作者丁']);
    });

    test('script/style 不进入文本', () {
      final r = HtmlRule(
        '<html><body><div id="c">正文<script>var a=1;</script>'
        '<style>.x{}</style>尾巴</div></body></html>',
      );
      expect(r.getString('#c@text'), '正文尾巴');
    });

    test('@html 会去掉 script/style', () {
      final r = HtmlRule(
        '<html><body><div id="c">正文<script>var a=1;</script></div></body></html>',
      );
      final html = r.getString('#c@html')!;
      expect(html, contains('正文'));
      expect(html, isNot(contains('script')));
    });

    test('属性存在选择器 [attr]', () {
      expect(rule().getStringList('img[data-src]@data-src'),
          ['//cdn.example.com/c.jpg']);
      expect(rule().getStringList('a[title]@title'), hasLength(4));
    });

    test('子代组合符 >', () {
      expect(rule().getStringList('ul#list > li > a@text'), hasLength(4));
    });

    test('后代 + 伪类混用', () {
      expect(rule().getStringList('ul#list li:gt(2) span@text'), ['作者丁']);
    });

    test('反向区间 [2:0]', () {
      expect(rule().getStringList('li[2:0]@text'),
          ['书名三 作者丙', '书名二 作者乙', '书名一 作者甲']);
    });

    test('nth-child 支持 odd/even 与 an+b 表达式', () {
      expect(rule().getStringList('ul#list > li:nth-child(odd) span@text'),
          ['作者甲', '作者丙']);
      expect(rule().getStringList('ul#list > li:nth-child(2n) span@text'),
          ['作者乙', '作者丁']);
      expect(rule().getStringList('ul#list > li:nth-child(-n+2) span@text'),
          ['作者甲', '作者乙']);
    });

    test('nth-last-child 从末尾数', () {
      expect(rule().getStringList('ul#list > li:nth-last-child(1) span@text'),
          ['作者丁']);
    });

    test('hasOwn 只匹配直接子元素', () {
      expect(rule().getStringList('ul#list > li:hasOwn(span.author) span@text'),
          hasLength(4));
      // div#own 的 span 是直接子元素，div#desc 的 p 也是；但 ul#list 没有 span 子元素
      expect(rule().getStringList('ul#list:hasOwn(span)@text'), isEmpty);
    });

    test('matchesOwn 只匹配自身文本节点', () {
      expect(rule().getStringList('span:matchesOwn(^作者[甲乙]\$)@text'),
          ['作者甲', '作者乙']);
    });

    test('is 选择器组', () {
      expect(
        rule().getStringList('#next:is(a, button)@text'),
        ['下一页'],
      );
      expect(rule().getStringList('#next:is(div)@text'), isEmpty);
    });

    test('不存在的选择器返回空', () {
      expect(rule().getStringList('li.nope@text'), isEmpty);
      expect(rule().getString('li.nope@text'), isNull);
      expect(rule().getString0('li.nope@text'), '');
    });
  });

  group('实体反转义', () {
    test('htmlUnescape4', () {
      expect(htmlUnescape4('a&amp;b&hellip;&#65;&nbsp;'), 'a&b…A\u00a0');
    });
  });
}
