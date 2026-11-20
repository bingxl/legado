import 'package:legado_core/src/rules/xpath_rule.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

XPathRule rule([String baseUrl = 'https://example.com/']) =>
    XPathRule(sampleHtml, baseUrl: baseUrl);

void main() {
  group('轴与基本取值', () {
    test('// 后代 + 属性', () {
      expect(rule().getStringList('//li/a/@href'), [
        '/book/1',
        '/book/2',
        '/book/3',
        '/book/4',
      ]);
    });

    test('/ 子节点', () {
      expect(rule().getStringList('/html/body/ul/li[1]/a/text()'), ['书名一']);
    });

    test('text() 取文本节点', () {
      expect(rule().getStringList('//li[1]/a/text()'), ['书名一']);
    });

    test('元素节点 asString 等于 jsoup 文本', () {
      expect(rule().getString('//li[1]'), '书名一 作者甲');
    });

    test('.. 父节点', () {
      expect(
        rule().getStringList('//a[@title="三号"]/../span/text()'),
        ['作者丙'],
      );
    });

    test('. 当前节点', () {
      expect(rule().getStringList('//div[@id="own"]/./text()'), ['自己']);
    });

    test('* 通配', () {
      expect(rule().getStringList('//div[@id="blocks"]/*/text()'), ['块一', '块二']);
    });
  });

  group('谓词', () {
    test('[n] 位置', () {
      expect(rule().getStringList('//li[2]/span/text()'), ['作者乙']);
    });

    test('[last()]', () {
      expect(rule().getStringList('//li[last()]/a/text()'), ['书名四']);
    });

    test('[@attr] 属性存在', () {
      expect(rule().getStringList('//img[@data-src]/@src'), ['/img/cover.jpg']);
    });

    test('[@attr="v"]', () {
      expect(rule().getStringList('//a[@title="二号"]/text()'), ['书名二']);
    });

    test('[@class="..."] 精确匹配', () {
      expect(rule().getStringList('//*[@class="item odd"]/a/@title'), ['一号', '三号']);
    });

    test('[contains(@a,"v")]', () {
      expect(
        rule().getStringList('//a[contains(@href,"/book/3")]/@title'),
        ['三号'],
      );
    });

    test('[text()="v"]', () {
      expect(rule().getStringList('//div[text()="块一"]/text()'), ['块一']);
    });

    test('[position()>n]', () {
      expect(rule().getStringList('//li[position()>2]/a/text()'), ['书名三', '书名四']);
    });

    test('and 组合谓词', () {
      expect(
        rule().getStringList(
          '//a[contains(@href,"book") and @title="三号"]/text()',
        ),
        ['书名三'],
      );
    });

    test('not() 取反', () {
      expect(
        rule().getStringList('//li[not(@class="item odd")]/a/text()'),
        ['书名二', '书名四'],
      );
    });

    test('多谓词串联', () {
      expect(
        rule().getStringList('//ul[@id="list"]/li[@class="item even"][1]/a/text()'),
        ['书名二'],
      );
    });
  });

  group('函数', () {
    test('starts-with', () {
      expect(
        rule().getStringList('//a[starts-with(@href,"/book")]/@title'),
        ['一号', '二号', '三号', '四号'],
      );
    });

    test('string-length', () {
      expect(
        rule().getStringList('//a[string-length(@title)=2]/@title'),
        ['一号', '二号', '三号', '四号'],
      );
    });

    test('normalize-space', () {
      expect(
        rule().getStringList('//a[normalize-space(text())="下一页"]/@href'),
        ['/toc?page=2'],
      );
    });

    test('substring-before', () {
      expect(
        rule().getStringList('//a[substring-before(@href,"/2")="/book"]/@title'),
        ['二号'],
      );
    });

    test('substring-after', () {
      expect(
        rule().getStringList('//a[substring-after(@href,"/book/")="4"]/@title'),
        ['四号'],
      );
    });

    test('concat', () {
      expect(
        rule().getStringList('//a[concat(@title,"!")="二号!"]/text()'),
        ['书名二'],
      );
    });

    test('count', () {
      expect(rule().getStringList('//div[@id="blocks"]/*[count(../*)>1]'), hasLength(2));
    });
  });

  group('组合与合并', () {
    test('&& 拼接', () {
      expect(rule().getStringList('//li[1]/a/@href && //a[@id="next"]/@href'),
          ['/book/1', '/toc?page=2']);
    });

    test('%% 交错', () {
      expect(
        rule().getStringList(
          '//li[1]/a/@href %% //li[2]/span/text() %% //li[3]/a/@href',
        ),
        ['/book/1', '作者乙', '/book/3'],
      );
    });

    test('空路径返回 null', () {
      expect(rule().getString(''), isNull);
      expect(rule().getNodes(''), isEmpty);
    });

    test('getNodes 长度', () {
      expect(rule().getNodes('//li'), hasLength(4));
    });
  });
}
