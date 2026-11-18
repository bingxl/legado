import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/explore/explore_results.dart';

Map<String, dynamic> _book({
  String name = '书',
  String author = '作者',
  String url = '',
  String origin = 'https://source.example',
}) {
  return {
    'name': name,
    'author': author,
    'bookUrl': url,
    'origin': origin,
  };
}

void main() {
  group('mergeResults', () {
    test('首页结果按顺序保留', () {
      final page1 = [_book(name: 'A', url: '/a'), _book(name: 'B', url: '/b')];
      final merged = mergeResults(const [], page1);
      expect(merged.map((e) => e['name']), ['A', 'B']);
    });

    test('同一本书不重复追加（末页重复返回上一页的情况）', () {
      final page1 = [_book(name: 'A', url: '/a'), _book(name: 'B', url: '/b')];
      final page2 = [_book(name: 'B', url: '/b'), _book(name: 'C', url: '/c')];
      final merged = mergeResults(page1, page2);
      expect(merged.map((e) => e['name']), ['A', 'B', 'C']);
    });

    test('不同书源的同一链接视为不同条目', () {
      final page1 = [_book(name: 'A', url: '/a', origin: 'https://s1')];
      final page2 = [_book(name: 'A', url: '/a', origin: 'https://s2')];
      expect(mergeResults(page1, page2), hasLength(2));
    });

    test('空页原样返回当前列表（用于判断到底）', () {
      final page1 = [_book(name: 'A', url: '/a')];
      expect(identical(mergeResults(page1, const []), page1), isTrue);
    });

    test('链接缺失时用书名 + 作者去重', () {
      final page1 = [_book(name: 'A', author: 'X')];
      final page2 = [_book(name: 'A', author: 'X'), _book(name: 'A', author: 'Y')];
      final merged = mergeResults(page1, page2);
      expect(merged, hasLength(2));
    });
  });
}
