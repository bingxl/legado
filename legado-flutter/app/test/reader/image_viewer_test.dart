import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/widgets/image_viewer_page.dart';

/// 看图页的图源归一化与定位是纯函数，直接单测。
/// 覆盖「双击第 N 张要打开第 N 张」这条最容易出错的路径。
void main() {
  group('resolveViewerSources', () {
    test('保留有效地址并按顺序定位被双击的那张', () {
      const urls = [
        'https://cdn.example.com/1.jpg',
        'https://cdn.example.com/2.jpg',
        'https://cdn.example.com/3.jpg',
      ];
      final result = resolveViewerSources(urls, urls[2]);
      expect(result, isNotNull);
      expect(result!.urls, urls);
      expect(result.index, 2);
    });

    test('协议相对地址补 https 后仍能定位到同一张', () {
      const urls = [
        '//cdn.example.com/a.jpg',
        'https://cdn.example.com/b.jpg',
      ];
      final result = resolveViewerSources(urls, '//cdn.example.com/a.jpg');
      expect(result, isNotNull);
      expect(result!.urls, ['https://cdn.example.com/a.jpg', urls[1]]);
      expect(result.index, 0);
    });

    test('剔除无效地址后按下标定重新定位', () {
      const urls = [
        '',
        '/relative/no-scheme.jpg',
        'https://cdn.example.com/a.jpg',
        'https://cdn.example.com/b.jpg',
      ];
      final result = resolveViewerSources(urls, 'https://cdn.example.com/b.jpg');
      expect(result, isNotNull);
      expect(result!.urls, [
        'https://cdn.example.com/a.jpg',
        'https://cdn.example.com/b.jpg',
      ]);
      expect(result.index, 1);
    });

    test('HTML 转义的 & 解开后能正确定位', () {
      const raw = 'https://cdn.example.com/a.jpg?x=1&amp;y=2';
      const clean = 'https://cdn.example.com/a.jpg?x=1&y=2';
      final result = resolveViewerSources([raw, clean], clean);
      expect(result, isNotNull);
      expect(result!.urls, [clean, clean]);
      // indexOf 取第一个匹配项。
      expect(result.index, 0);
    });

    test('被双击的地址不在列表里时回退到第一张', () {
      final result = resolveViewerSources(
        ['https://cdn.example.com/a.jpg'],
        'https://other.example.com/x.jpg',
      );
      expect(result, isNotNull);
      expect(result!.index, 0);
    });

    test('整组没有有效地址时返回 null', () {
      expect(
        resolveViewerSources(['', '/rel/a.jpg', 'ftp://x/y.gif'], 'x'),
        isNull,
      );
      expect(resolveViewerSources(const [], 'x'), isNull);
    });
  });
}
