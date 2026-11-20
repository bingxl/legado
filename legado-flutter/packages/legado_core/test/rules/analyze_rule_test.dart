import 'package:legado_core/src/rules/analyze_rule.dart';
import 'package:legado_core/src/rules/rule.dart';
import 'package:legado_core/src/rules/xpath_rule.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

SimpleRuleContext ctx({FakeJsEngine? js, String baseUrl = 'https://example.com'}) =>
    SimpleRuleContext(js: js ?? FakeJsEngine(), baseUrl: baseUrl);

void main() {
  group('模式识别', () {
    test('@css: 前缀', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getStringList('@css:li a@href', sampleHtml),
          ['/book/1', '/book/2', '/book/3', '/book/4']);
    });

    test('@XPath: 前缀', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getStringList('@XPath://li[2]/a/@href', sampleHtml),
          ['/book/2']);
    });

    test('@Json: 前缀', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString(r'@Json:$.data.total', sampleJson), '3');
    });

    test('内容是 JSON 时默认按 JSONPath 解析', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString(r'$.data.total', sampleJson), '3');
      expect(await r.getString('data.meta.name', sampleJson), 'abcd');
    });

    test('规则以 // 开头时按 XPath 解析', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('//li[1]/a/@href', sampleHtml), '/book/1');
    });

    test('@@ 强制按 CSS 解析（内容是 JSON 也不转 JSONPath）', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('@@li:eq(0) a@text', sampleHtml), '书名一');
    });
  });

  group('JS 段', () {
    test('<js> 段返回结果', () async {
      final js = FakeJsEngine(handler: (s, b) => s.trim() == '1+1' ? '2' : null);
      final r = AnalyzeRule(ctx(js: js));
      expect(await r.getString('<js>1+1</js>', sampleHtml), '2');
    });

    test('@js: 段能拿到 result', () async {
      final js = FakeJsEngine(
        handler: (s, b) =>
            s.trim() == "result+'!'" ? '${b['result']}!' : null,
      );
      final r = AnalyzeRule(ctx(js: js));
      expect(await r.getString('li:eq(0) a@text@js:result+\'!\'', sampleHtml),
          '书名一!');
    });

    test('JS 产出的 HTML 可被后续选择器接力解析', () async {
      final js = FakeJsEngine(
        handler: (s, b) => s.trim() == 'makeHtml()'
            ? '<ul><li><a href="/j/1">J1</a></li><li><a href="/j/2">J2</a></li></ul>'
            : null,
      );
      final r = AnalyzeRule(ctx(js: js));
      expect(await r.getStringList('<js>makeHtml()</js>li a@href', sampleHtml),
          ['/j/1', '/j/2']);
    });
  });

  group('变量：@put / @get', () {
    test('@put 写入变量（值本身是规则）', () async {
      final c = ctx();
      final r = AnalyzeRule(c);
      final value = await r.getString(
        '@put:{"bid":"li:eq(2) a@href"}li:eq(0) a@href',
        sampleHtml,
      );
      expect(value, '/book/1');
      expect(c.variables['bid'], '/book/3');
    });

    test('@get 读取变量', () async {
      final c = ctx();
      c.variables['bid'] = '/book/9';
      final r = AnalyzeRule(c);
      expect(await r.getString('@get:{bid}', sampleHtml), '/book/9');
    });

    test('{{规则}} 在起始位置按规则递归求值', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString(r'{{$.data.total}}', sampleJson), '3');
    });

    test('{{JS表达式}} 求值', () async {
      final js = FakeJsEngine(handler: (s, b) => s.trim() == '1+1' ? 2 : null);
      final r = AnalyzeRule(ctx(js: js));
      expect(await r.getString('{{1+1}}', sampleHtml), '2');
    });
  });

  group('正则替换', () {
    test('##regex##replacement 全量替换', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('li a@href##/book/##B', sampleHtml),
          'B1\nB2\nB3\nB4');
    });

    test(r'替换串支持 $1 分组', () async {
      final r = AnalyzeRule(ctx());
      expect(
        await r.getString(r'li:eq(0) a@href##/book/(\d+)##book-$1', sampleHtml),
        'book-1',
      );
    });

    test('##regex## 删除匹配', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('li:eq(0) a@text##书名##', sampleHtml), '一');
    });

    test('### 只替换首个匹配', () async {
      final r = AnalyzeRule(ctx());
      expect(
        await r.getString(r'li:eq(0) a@href##/book/\d+##X###', sampleHtml),
        'X',
      );
    });
  });

  group('输出与细节', () {
    test('isUrl 绝对化并去重', () async {
      final r = AnalyzeRule(ctx());
      expect(
        await r.getStringList('li a@href', sampleHtml, true),
        [
          'https://example.com/book/1',
          'https://example.com/book/2',
          'https://example.com/book/3',
          'https://example.com/book/4',
        ],
      );
    });

    test('getString(isUrl) 对空结果回落到 baseUrl', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('li.none@href', sampleHtml, true),
          'https://example.com');
    });

    test('结果做 HTML 实体反转义', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString(r'$.a', '{"a":"a&amp;b"}'), 'a&b');
    });

    test('getElements：CSS', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getElements('li', sampleHtml), hasLength(4));
    });

    test('getElements：JSONPath', () async {
      final r = AnalyzeRule(ctx());
      final list = await r.getElements(r'$.data.list', sampleJson);
      expect(list, hasLength(3));
      expect((list.first as Map)['name'], '甲');
    });

    test('getElements：XPath', () async {
      final r = AnalyzeRule(ctx());
      final list = await r.getElements('//li', sampleHtml);
      expect(list, hasLength(4));
      expect(list.first, isA<XElementValue>());
    });

    test('getElement 取第一个', () async {
      final r = AnalyzeRule(ctx());
      final one = await r.getElement(r'$.data.list', sampleJson);
      expect((one as Map)['id'], 1);
    });

    test('空规则返回空', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getString('', sampleHtml), '');
      expect(await r.getStringList(null, sampleHtml), isEmpty);
      expect(await r.getElements('', sampleHtml), isEmpty);
    });

    test('getStringEx 与 getString 等价', () async {
      final r = AnalyzeRule(ctx());
      expect(await r.getStringEx('li:eq(0) a@href', sampleHtml), '/book/1');
    });
  });
}
