import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/html_text.dart';

void main() {
  group('HtmlText.toParagraphs', () {
    test('块级标签切段，行内标签丢弃', () {
      final paragraphs = HtmlText.toParagraphs(
        '<div><p>第一段<strong>加粗</strong>文字</p><p>第二段</p></div>',
      );
      expect(paragraphs, ['第一段加粗文字', '第二段']);
    });

    test('<br> 视为换行', () {
      final paragraphs = HtmlText.toParagraphs('第一行<br/>第二行<br>第三行');
      expect(paragraphs, ['第一行', '第二行', '第三行']);
    });

    test('HTML 源码里的裸换行不会产生空段落', () {
      final paragraphs = HtmlText.toParagraphs('''
        <p>第一段</p>
        <p>第二段</p>
      ''');
      expect(paragraphs, ['第一段', '第二段']);
    });

    test('连续空行压缩成一个空段落，首尾空行丢弃', () {
      final paragraphs = HtmlText.toParagraphs('开头<br><br><br>结尾<br><br>');
      expect(paragraphs, ['开头', '', '结尾']);
    });

    test('解码命名实体与数字实体', () {
      final paragraphs = HtmlText.toParagraphs(
        'A&nbsp;&amp;&nbsp;B&#33;&#x4E2D;&hellip;',
      );
      expect(paragraphs.single, 'A & B!中…');
    });

    test('script / style / 注释内容不进入正文', () {
      final paragraphs = HtmlText.toParagraphs(
        '<style>.a{color:red}</style><!-- 隐藏 --><p>正文</p><script>alert(1)</script>',
      );
      expect(paragraphs, ['正文']);
    });

    test('属性里带 > 的标签也能被吞掉', () {
      final paragraphs = HtmlText.toParagraphs('<span data-x="a>b">文字</span>');
      // 简化解析不追求 100% 正确，但不能把正文丢掉或抛异常。
      expect(paragraphs.join(), contains('文字'));
    });

    test('空 HTML 返回空列表', () {
      expect(HtmlText.toParagraphs(''), isEmpty);
      expect(HtmlText.toParagraphs('   \n\r\t '), isEmpty);
    });

    test('全角空格缩进被规整为单个半角空格后去除首尾', () {
      final paragraphs = HtmlText.toParagraphs('<p>　　这一行自带缩进</p>');
      expect(paragraphs.single, '这一行自带缩进');
    });
  });

  group('HtmlText.toContent 正文图片', () {
    test('图片独立成段并保留在正文中的位置', () {
      final content = HtmlText.toContent(
        '<p>前文</p><img src="https://img.test/a.jpg"><p>后文</p>',
      );
      expect(content.paragraphs, ['前文', '', '后文']);
      expect(content.imageUrls, {1: 'https://img.test/a.jpg'});
      expect(content.hasText, isTrue);
    });

    test('懒加载属性与转义字符也能取到图片地址', () {
      final content = HtmlText.toContent(
        '<p>插图</p><img data-src="https://img.test/x.jpg?a=1&amp;b=2">',
      );
      expect(content.imageUrls.values.single, 'https://img.test/x.jpg?a=1&b=2');
    });

    test('纯图片章节没有文字', () {
      final content = HtmlText.toContent('<img src="https://img.test/1.jpg">');
      expect(content.hasText, isFalse);
      expect(content.imageUrls.length, 1);
    });
  });
}
