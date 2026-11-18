import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/rss/rss_text.dart';

void main() {
  group('stripHtml', () {
    test('块级标签切段，行内标签丢弃', () {
      expect(
        RssText.stripHtml('<p>Hello <b>world</b></p><p>Second</p>'),
        'Hello world\n\nSecond',
      );
    });

    test('<br> 视为段内换行', () {
      expect(RssText.stripHtml('第一行<br>第二行'), '第一行\n第二行');
    });

    test('丢弃 script/style 内容', () {
      const html = '<style>.a{color:red}</style>'
          '<script>alert(1)</script>'
          '<p>正文</p>';
      expect(RssText.stripHtml(html), '正文');
    });

    test('实体解码：命名、十进制、十六进制', () {
      expect(
        RssText.stripHtml('a&nbsp;b &amp; &#39;q&#39; &#x4e2d;'),
        "a b & 'q' 中",
      );
    });

    test('未知实体原样保留', () {
      expect(RssText.stripHtml('&unknownentity;'), '&unknownentity;');
    });

    test('空输入返回空串', () {
      expect(RssText.stripHtml(null), '');
      expect(RssText.stripHtml('   '), '');
    });

    test('压缩行内空白与多余空行', () {
      expect(RssText.stripHtml('<p>a    b</p><p></p><p>c</p>'), 'a b\n\nc');
    });
  });

  group('snippet', () {
    test('压成一行并截断', () {
      final text = RssText.snippet('<p>${'字' * 120}</p>', maxLength: 10);
      expect(text, '${'字' * 10}…');
    });

    test('短文本不加省略号', () {
      expect(RssText.snippet('<p>短</p>'), '短');
    });
  });

  group('时间格式', () {
    test('未知时间返回空串', () {
      expect(RssText.formatTime(0), '');
    });

    test('一小时内显示分钟', () {
      final ts = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch ~/
          1000;
      expect(RssText.formatTime(ts), '5 分钟前');
    });

    test('一天内显示小时', () {
      final ts = DateTime.now()
          .subtract(const Duration(hours: 3))
          .millisecondsSinceEpoch ~/
          1000;
      expect(RssText.formatTime(ts), '3 小时前');
    });

    test('完整时间按本地时区格式化', () {
      final time = DateTime(2024, 3, 4, 5, 6);
      expect(
        RssText.formatDateTime(time.millisecondsSinceEpoch ~/ 1000),
        '2024-03-04 05:06',
      );
    });
  });

  group('hostOf', () {
    test('取 host', () {
      expect(RssText.hostOf('https://example.com/a/b.xml'), 'example.com');
    });

    test('空地址返回空串', () {
      expect(RssText.hostOf(''), '');
      expect(RssText.hostOf(null), '');
    });
  });

  group('validateFeedUrl', () {
    test('空地址报错', () {
      expect(RssText.validateFeedUrl(''), '订阅地址不能为空');
    });

    test('非 http/https 协议报错', () {
      expect(
        RssText.validateFeedUrl('ftp://example.com/feed.xml'),
        '需要以 http:// 或 https:// 开头',
      );
    });

    test('合法地址通过', () {
      expect(RssText.validateFeedUrl('http://example.com/feed.xml'), isNull);
      expect(RssText.validateFeedUrl('https://example.com/feed.xml'), isNull);
    });

    test('缺少域名报错', () {
      expect(RssText.validateFeedUrl('https://'), isNotNull);
    });
  });
}
