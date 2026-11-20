import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:legado/core/image_url.dart';
import 'package:legado/core/widgets/book_cover.dart';

void main() {
  group('normalizeImageUrl', () {
    test('http/https 绝对地址原样保留', () {
      expect(
        normalizeImageUrl(' https://p6.ecombdimg.com/a.jpg '),
        'https://p6.ecombdimg.com/a.jpg',
      );
      expect(
        normalizeImageUrl('http://yumanhua.com/static/a.jpg'),
        'http://yumanhua.com/static/a.jpg',
      );
    });

    test('协议相对地址补 https', () {
      expect(normalizeImageUrl('//cdn.example.com/a.jpg'),
          'https://cdn.example.com/a.jpg');
    });

    test('还原 HTML 实体，避免签名参数被截断', () {
      expect(
        normalizeImageUrl('https://cdn.example.com/a.jpg?x=1&amp;y=2'),
        'https://cdn.example.com/a.jpg?x=1&y=2',
      );
    });

    test('空串、相对路径、非 http 协议返回 null', () {
      expect(normalizeImageUrl(null), isNull);
      expect(normalizeImageUrl('  '), isNull);
      expect(normalizeImageUrl('/img/a.jpg'), isNull);
      expect(normalizeImageUrl('a.jpg'), isNull);
      expect(normalizeImageUrl('data:image/png;base64,AAAA'), isNull);
      expect(normalizeImageUrl('file:///tmp/a.jpg'), isNull);
    });
  });

  testWidgets('没有可用封面时用书名首字兜底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: BookCover(name: '斗破苍穹', url: '', width: 80, height: 110),
          ),
        ),
      ),
    );

    expect(find.text('斗'), findsOneWidget);
  });
}
