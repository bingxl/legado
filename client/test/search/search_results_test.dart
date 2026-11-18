import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/search/search_results.dart';

Map<String, dynamic> _item({
  String name = '书',
  String author = '作者',
  String url = '',
  String origin = 'https://source.example',
  String originName = '',
}) {
  return {
    'name': name,
    'author': author,
    'bookUrl': url,
    'origin': origin,
    'originName': originName,
  };
}

void main() {
  group('groupBySource', () {
    test('按首次出现顺序分组并统计数量', () {
      final groups = groupBySource([
        _item(name: 'A', originName: '源一'),
        _item(name: 'B', originName: '源二'),
        _item(name: 'C', originName: '源一'),
      ]);
      expect(groups.map((g) => g.name), ['源一', '源二']);
      expect(groups[0].items.map((e) => e['name']), ['A', 'C']);
      expect(groups[1].items, hasLength(1));
    });

    test('originName 缺失时回退 origin 地址', () {
      final groups = groupBySource([
        _item(origin: 'https://a.example'),
        _item(origin: 'https://a.example'),
      ]);
      expect(groups.single.name, 'https://a.example');
      expect(groups.single.items, hasLength(2));
    });

    test('两个字段都缺失时归到「未知书源」', () {
      final groups = groupBySource([
        _item(origin: '', originName: ''),
      ]);
      expect(groups.single.name, '未知书源');
    });

    test('空结果返回空分组', () {
      expect(groupBySource(const []), isEmpty);
    });
  });

  group('mergeSearchResults', () {
    test('跨页去重且保持顺序', () {
      final page1 = [_item(name: 'A', url: '/a'), _item(name: 'B', url: '/b')];
      final page2 = [_item(name: 'B', url: '/b'), _item(name: 'C', url: '/c')];
      final merged = mergeSearchResults(page1, page2);
      expect(merged.map((e) => e['name']), ['A', 'B', 'C']);
    });

    test('不同来源的相同链接保留', () {
      final merged = mergeSearchResults(
        [_item(url: '/a', origin: 'https://s1')],
        [_item(url: '/a', origin: 'https://s2')],
      );
      expect(merged, hasLength(2));
    });
  });
}
