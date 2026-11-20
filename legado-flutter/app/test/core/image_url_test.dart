import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/image_url.dart';

void main() {
  group('normalizeImageUrl', () {
    test('协议相对地址补 https，HTML 实体解开', () {
      expect(
        normalizeImageUrl('//cdn.test/a.jpg?x=1&amp;y=2'),
        'https://cdn.test/a.jpg?x=1&y=2',
      );
    });

    test('相对路径与非 http 协议不接受', () {
      expect(normalizeImageUrl('/img/a.jpg'), isNull);
      expect(normalizeImageUrl('data:image/png;base64,AA'), isNull);
      expect(normalizeImageUrl(null), isNull);
    });
  });

  group('imageHeaders', () {
    test('用图片自身的 origin 作 Referer，能过常见 CDN 防盗链', () {
      final headers = imageHeaders('https://p.ananas.chaoxing.com/star3/a.jpg');
      expect(headers['Referer'], 'https://p.ananas.chaoxing.com/');
      expect(headers['User-Agent'], contains('Mozilla/5.0'));
    });

    test('非法地址也带浏览器 UA，但不伪造 Referer', () {
      final headers = imageHeaders('not a url');
      expect(headers.containsKey('Referer'), isFalse);
      expect(headers['User-Agent'], contains('Mozilla/5.0'));
    });
  });
}
