import 'package:legado_core/src/rules/rule.dart';
import 'package:legado_core/src/rules/url_rule.dart';
import 'package:legado_core/src/util/url.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('URL 工具', () {
    test('isAbsUrl / isDataUrl', () {
      expect(isAbsUrl('https://a.com'), isTrue);
      expect(isAbsUrl('HTTPS://a.com'), isTrue);
      expect(isAbsUrl('/a/b'), isFalse);
      expect(isDataUrl('data:image/png;base64,xx'), isTrue);
    });

    test('getBaseUrl', () {
      expect(getBaseUrl('https://a.com/b/c?x=1'), 'https://a.com');
      expect(getBaseUrl('https://a.com'), 'https://a.com');
      expect(getBaseUrl('ftp://a.com'), isNull);
      expect(getBaseUrl(null), isNull);
    });

    test('相对地址绝对化', () {
      expect(
        getAbsoluteUrl('https://a.com/b/c.html', '../d/e.html'),
        'https://a.com/d/e.html',
      );
      expect(getAbsoluteUrl('https://a.com/b/', 'x.html'),
          'https://a.com/b/x.html');
      expect(getAbsoluteUrl('https://a.com', '/x'), 'https://a.com/x');
      expect(getAbsoluteUrl('https://a.com/b', '//cdn.x.com/a.js'),
          'https://cdn.x.com/a.js');
      expect(getAbsoluteUrl('https://a.com/b?x=1', '?y=2'),
          'https://a.com/b?y=2');
      // 带端口的 origin（本地测试服务器 / 自建站点）不能被丢掉。
      expect(getAbsoluteUrl('http://127.0.0.1:8080/b/', 'x.html'),
          'http://127.0.0.1:8080/b/x.html');
      expect(getAbsoluteUrl('http://127.0.0.1:8080/b', '/x'),
          'http://127.0.0.1:8080/x');
    });

    test('已是绝对地址 / data: 原样返回', () {
      expect(getAbsoluteUrl('https://a.com', 'https://b.com/x'),
          'https://b.com/x');
      expect(getAbsoluteUrl('https://a.com', 'data:text/plain,hi'),
          'data:text/plain,hi');
    });

    test('javascript: 返回空串', () {
      expect(getAbsoluteUrl('https://a.com', 'javascript:void(0)'), '');
    });

    test('未替换的模板保持原样（不做百分号转义）', () {
      expect(
        getAbsoluteUrl('https://a.com/', '/list/{{key}}/{{page}}.html'),
        'https://a.com/list/{{key}}/{{page}}.html',
      );
    });

    test('baseUrl 为空时返回相对串', () {
      expect(getAbsoluteUrl('', '/a/b'), '/a/b');
    });

    test('base 带 ,{...} 选项时只取前段', () {
      expect(
        getAbsoluteUrl('https://a.com/b,{"method":"POST"}', 'c'),
        'https://a.com/c',
      );
    });
  });

  group('AnalyzeUrl', () {
    UrlRuleAnalyzer analyzer({String? key, int? page, FakeJsEngine? js}) =>
        UrlRuleAnalyzer(
          SimpleRuleContext(js: js ?? FakeJsEngine()),
          key: key,
          page: page,
        );

    test('{{key}} / {{page}} 替换并编码', () async {
      final r = await analyzer(key: '斗破', page: 2)
          .analyze('https://a.com/search?q={{key}}&p={{page}}');
      expect(r.url, 'https://a.com/search?q=%E6%96%97%E7%A0%B4&p=2');
      expect(r.urlNoQuery, 'https://a.com/search');
      expect(r.encodedQuery, 'q=%E6%96%97%E7%A0%B4&p=2');
    });

    test('<1,2,3> 分页占位', () async {
      final r = await analyzer(page: 2)
          .analyze('https://a.com/list/<1,2,3>.html');
      expect(r.url, 'https://a.com/list/2.html');
    });

    test('分页越界取最后一段', () async {
      final r = await analyzer(page: 9)
          .analyze('https://a.com/list/<1,2,3>.html');
      expect(r.url, 'https://a.com/list/3.html');
    });

    test('相对地址按 baseUrl 绝对化', () async {
      final r = await analyzer(key: 'x')
          .analyze('/search?q={{key}}', baseUrl: 'https://a.com');
      expect(r.url, 'https://a.com/search?q=x');
      expect(r.baseUrl, 'https://a.com');
    });

    test(',{...} 选项：POST + 头 + 表单编码', () async {
      final r = await analyzer().analyze(
        'https://a.com/api,{"method":"POST","headers":{"X-Token":"t"},'
        '"body":"a=1&b=二"}',
      );
      expect(r.method, 'POST');
      expect(r.urlNoQuery, 'https://a.com/api');
      expect(r.headers['X-Token'], 't');
      expect(r.body, 'a=1&b=二');
      expect(r.encodedForm, 'a=1&b=%E4%BA%8C');
    });

    test('选项 JSON 宽松解析（单引号 + 多余逗号）', () async {
      final r = await analyzer()
          .analyze("https://a.com/api,{'method':'POST', 'retry':2,}");
      expect(r.method, 'POST');
      expect(r.retry, 2);
    });

    test('选项里的 charset', () async {
      final r = await analyzer()
          .analyze('https://a.com/api,{"charset":"gbk"}');
      expect(r.charset, 'gbk');
    });

    test('@js: 整条规则求值', () async {
      final js = FakeJsEngine(
        handler: (script, bindings) {
          if (script.trim() == 'buildUrl()') return 'https://a.com/x';
          return null;
        },
      );
      final r = await analyzer(js: js).analyze('@js:buildUrl()');
      expect(r.url, 'https://a.com/x');
      expect(js.scripts, contains('buildUrl()'));
    });

    test('{{ }} 求值为空串时仍替换掉整段', () async {
      final js = FakeJsEngine(handler: (script, bindings) => '');
      final r = await analyzer(js: js)
          .analyze('https://a.com/allbook{{page === 1}}.html');
      expect(r.url, 'https://a.com/allbook.html');
    });

    test('已是编码的 query 不重复编码', () async {
      final r = await analyzer()
          .analyze('https://a.com/s?q=%E6%96%97%E7%A0%B4');
      expect(r.encodedQuery, 'q=%E6%96%97%E7%A0%B4');
    });

    test('data: 地址原样保留', () async {
      final r = await analyzer().analyze('data:text/plain,hello');
      expect(r.url, 'data:text/plain,hello');
    });

    test('charset=gbk 时查询串按 GBK 取字节（不是 UTF-8）', () async {
      // GBK 站点把 UTF-8 的 %E4%B8%AD 当 GBK 解会成乱码，搜索直接 0 条。
      final r = await analyzer()
          .analyze('https://a.com/s?q=中文,{"charset":"gbk"}');
      expect(r.encodedQuery, 'q=%D6%D0%CE%C4');
    });
  });
}
