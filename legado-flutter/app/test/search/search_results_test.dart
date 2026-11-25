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

  group('mergeSearchResultsByRelevance', () {
    test('完全匹配 > 包含匹配 > 其它', () {
      final merged = mergeSearchResultsByRelevance(
        const [],
        [
          _item(name: '无关书', url: '/other'),
          _item(name: '剑来前传', author: '作者甲', url: '/prequel'),
          _item(name: '剑来', author: '作者甲', url: '/main'),
        ],
        keyword: '剑来',
        precision: false,
      );
      expect(merged.map((e) => e['name']), ['剑来', '剑来前传', '无关书']);
    });

    test('同名同作者合并来源，来源多的优先', () {
      final merged = mergeSearchResultsByRelevance(
        const [],
        [
          _item(name: '同一本', url: '/a', origin: 's1'),
          _item(name: '同一本', url: '/b', origin: 's2'),
        ],
        keyword: '同一本',
        precision: false,
      );
      expect(merged, hasLength(1));
      expect(merged.single['name'], '同一本');
      expect((merged.single['origins'] as List), ['s1', 's2']);
    });

    test('组内按来源数降序且数量相同时保持原顺序', () {
      final merged = mergeSearchResultsByRelevance(
        const [],
        [
          _item(name: '剑来前传', url: '/one', origin: 's1'),
          _item(name: '剑来外传', url: '/two', origin: 's2'),
          _item(name: '剑来前传', url: '/three', origin: 's3'),
        ],
        keyword: '剑来',
        precision: false,
      );
      // 前传合并了 2 个来源；外传只有 1 个，虽然先出现也排到后面。
      expect(merged.map((e) => e['name']), ['剑来前传', '剑来外传']);
    });

    test('精确搜索丢弃书名作者都不含关键词的结果', () {
      final merged = mergeSearchResultsByRelevance(
        const [],
        [
          _item(name: '无关书', url: '/other'),
          _item(name: '剑来', url: '/main'),
        ],
        keyword: '剑来',
        precision: true,
      );
      expect(merged.map((e) => e['name']), ['剑来']);
    });

    test('跨页合并后按相关性重排，而不是按页顺序追加', () {
      final merged = mergeSearchResultsByRelevance(
        [_item(name: '无关书', url: '/other')],
        [_item(name: '剑来', url: '/main')],
        keyword: '剑来',
        precision: false,
      );
      expect(merged.map((e) => e['name']), ['剑来', '无关书']);
    });
  });
}
