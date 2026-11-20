import 'dart:convert';

import 'package:legado_core/src/rules/json_path_rule.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

JsonPathRule rule() => JsonPathRule(sampleJson);

void main() {
  group('基本路径', () {
    test(r'$.a.b 逐级取值', () {
      expect(rule().getString(r'$.data.total'), '3');
      expect(rule().getString(r'$.data.meta.name'), 'abcd');
    });

    test(r'$["a"] 方括号键', () {
      expect(rule().getString(r"$['data']['list'][1]['author']"), 'B');
    });

    test(r'$[0] / $[-1] 数组下标', () {
      expect(rule().getString(r'$.data.list[0].name'), '甲');
      expect(rule().getString(r'$.data.list[-1].name'), '丙');
    });

    test(r'$[*] 通配', () {
      expect(rule().getStringList(r'$.data.list[*].name'), ['甲', '乙', '丙']);
      expect(rule().getStringList(r'$.data.list[*].tags[*]'), ['x', 'y', 'y']);
    });

    test(r'不以 $ 开头时自动补前缀', () {
      expect(rule().getString('data.total'), '3');
      expect(rule().getStringList(r'data.list[*].id'), ['1', '2', '3']);
    });

    test(r'$..a 递归下降', () {
      expect(rule().getStringList(r'$..name'), ['甲', '乙', '丙', 'abcd']);
    });

    test(r'$..* 递归取全部', () {
      expect(rule().read(r'$..*'), isNotEmpty);
    });

    test('切片 [start:end]', () {
      expect(rule().getStringList(r'$.data.list[0:2].name'), ['甲', '乙']);
    });

    test('联合 [0,2]', () {
      expect(rule().getStringList(r'$.data.list[0,2].name'), ['甲', '丙']);
    });
  });

  group('过滤', () {
    test('存在性 [?(@.title)]', () {
      expect(rule().getStringList(r'.[?(@.title)].title'), ['嵌套甲', '嵌套乙']);
      expect(rule().getStringList(r'$..[?(@.title)].title'), ['嵌套甲', '嵌套乙']);
    });

    test('相等 [?(@.k=="v")]', () {
      expect(rule().getStringList(r"$.data.list[?(@.name=='乙')].id"), ['2']);
    });

    test('数值比较', () {
      expect(rule().getStringList(r'$.data.list[?(@.words>150)].name'), ['乙', '丙']);
    });

    test('布尔字段', () {
      expect(rule().getStringList(r'$.data.list[?(@.vip)].name'), ['甲', '丙']);
    });

    test('正则匹配 =~ /re/', () {
      expect(
        rule().getStringList(r'$.data.list[?(@.author=~/^[AB]$/)].name'),
        ['甲', '乙'],
      );
    });

    test('省略 ? 的过滤写法 [@.k=~/re/]', () {
      expect(
        rule().getStringList(r'$.data.list[@.name=~/^丙$/].id'),
        ['3'],
      );
    });

    test('&& 组合', () {
      expect(rule().getStringList(r'$.data.list[?(@.id>1 && @.vip)].name'), ['丙']);
    });

    test('|| 组合', () {
      expect(
        rule().getStringList(r'$.data.list[?(@.id==1 || @.id==3)].name'),
        ['甲', '丙'],
      );
    });

    test('过滤后为空不报错', () {
      expect(rule().getString(r'$.data.list[?(@.id>99)].name'), '');
    });
  });

  group('聚合函数', () {
    test('length()', () {
      expect(rule().getString(r'$.data.list.length()'), '3');
      expect(rule().getString(r'$.data.meta.name.length()'), '4');
      expect(rule().getString(r'$.data.meta.obj.length()'), '2');
    });

    test('min/max/sum/avg', () {
      expect(rule().getString(r'$.data.list[*].words.min()'), '100');
      expect(rule().getString(r'$.data.list[*].words.max()'), '300');
      expect(rule().getString(r'$.data.list[*].words.sum()'), '600');
      expect(rule().getString(r'$.data.list[*].words.avg()'), '200');
    });
  });

  group('输出形态', () {
    test('getStringList 按元素展开', () {
      expect(rule().getStringList(r'$.data.list[*].name'), hasLength(3));
    });

    test('getString 多值换行连接', () {
      expect(rule().getString(r'$.data.list[*].name'), '甲\n乙\n丙');
    });

    test('getList 取对象列表', () {
      expect(rule().getList(r'$.data.list'), hasLength(3));
    });

    test('getObject 取单个对象', () {
      final obj = rule().getObject(r'$.data.meta');
      expect(obj, isA<Map<String, Object?>>());
      expect((obj as Map)['name'], 'abcd');
    });

    test(r'内嵌规则 {$.x}', () {
      expect(rule().getString('共{\$.data.total}本'), '共3本');
    });

    test('无命中返回空串', () {
      expect(rule().getString(r'$.nope.nope'), '');
      expect(rule().getStringList(r'$.nope'), isEmpty);
    });

    test('%% 交错合并', () {
      expect(
        rule().getStringList(r'$.data.list[0:1].name %% $.data.list[1:2].name'),
        ['甲', '乙'],
      );
    });
  });

  group('根为数组', () {
    test(r'$[*] / $.[0] 归一化', () {
      final r = JsonPathRule(jsonEncode([
        {'n': 'a'},
        {'n': 'b'},
      ]));
      expect(r.getStringList(r'$[*].n'), ['a', 'b']);
      expect(r.getString(r'$.[0].n'), 'a');
    });
  });
}
