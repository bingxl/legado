import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/source/source_utils.dart';

void main() {
  group('domainOf', () {
    test('取主机名', () {
      expect(SourceUtils.domainOf('https://www.example.com/a/b?c=1'), 'www.example.com');
      expect(SourceUtils.domainOf('  https://a.b.c  '), 'a.b.c');
    });

    test('非法 URL 退化为原串', () {
      expect(SourceUtils.domainOf('not a url'), 'not a url');
      expect(SourceUtils.domainOf(''), '');
    });
  });

  group('splitGroups', () {
    test('支持中英文逗号与分号', () {
      expect(SourceUtils.splitGroups('A,B；C，D;E'), ['A', 'B', 'C', 'D', 'E']);
    });

    test('空值返回空列表', () {
      expect(SourceUtils.splitGroups(null), isEmpty);
      expect(SourceUtils.splitGroups('  '), isEmpty);
      expect(SourceUtils.splitGroups(',,'), isEmpty);
    });
  });

  group('过滤', () {
    final src = <String, dynamic>{
      'name': '起点中文',
      'url': 'https://www.qidian.com',
      'group': '小说, 男频',
    };

    test('matchesQuery 命中名称/地址/分组', () {
      expect(SourceUtils.matchesQuery(src, '起点'), isTrue);
      expect(SourceUtils.matchesQuery(src, 'QIDIAN'), isTrue);
      expect(SourceUtils.matchesQuery(src, '男频'), isTrue);
      expect(SourceUtils.matchesQuery(src, '不可能'), isFalse);
      expect(SourceUtils.matchesQuery(src, '  '), isTrue);
    });

    test('inGroup 按逗号切分后精确匹配', () {
      expect(SourceUtils.inGroup(src, ''), isTrue);
      expect(SourceUtils.inGroup(src, '小说'), isTrue);
      expect(SourceUtils.inGroup(src, '男'), isFalse);
    });
  });

  group('checkRawJson', () {
    test('空内容视为未填写，不算错', () {
      expect(SourceUtils.checkRawJson('   '), isNull);
    });

    test('合法对象通过', () {
      expect(SourceUtils.checkRawJson('{"bookSourceUrl":"https://a.com"}'), isNull);
    });

    test('数组不是单个书源', () {
      expect(SourceUtils.checkRawJson('[]'), contains('JSON 对象'));
    });

    test('语法错误给出提示', () {
      final err = SourceUtils.checkRawJson('{"a": }');
      expect(err, isNotNull);
      expect(err, contains('JSON 格式错误'));
    });
  });

  group('prettyJson', () {
    test('压缩 JSON 会被格式化', () {
      expect(
        SourceUtils.prettyJson('{"a":1,"b":[2]}'),
        '{\n  "a": 1,\n  "b": [\n    2\n  ]\n}',
      );
    });

    test('非法 JSON 原样返回', () {
      expect(SourceUtils.prettyJson('{oops'), '{oops');
    });
  });

  group('extractRawFields', () {
    test('提取关键字段', () {
      final fields = SourceUtils.extractRawFields(
        '{"bookSourceName":"A","bookSourceUrl":"https://a.com",'
        '"bookSourceGroup":"g","bookSourceComment":"c"}',
      );
      expect(fields['name'], 'A');
      expect(fields['url'], 'https://a.com');
      expect(fields['group'], 'g');
      expect(fields['comment'], 'c');
    });

    test('缺失或非法时返回空', () {
      expect(SourceUtils.extractRawFields('{"other":1}'), isEmpty);
      expect(SourceUtils.extractRawFields('not json'), isEmpty);
    });
  });

  group('导入结果', () {
    test('汇总计数', () {
      final msg = SourceUtils.importSummary({
        'imported': 2,
        'updated': 1,
        'skipped': 3,
        'failures': [
          {'name': 'x', 'reason': 'y'},
        ],
      });
      expect(msg, '新增 2 / 更新 1 / 跳过 3 / 失败 1');
    });

    test('无失败时不追加失败项', () {
      expect(
        SourceUtils.importSummary({'imported': 1}),
        '新增 1 / 更新 0 / 跳过 0',
      );
    });

    test('第一条失败原因', () {
      expect(
        SourceUtils.firstImportFailure({
          'failures': [
            {'name': '坏源', 'reason': '解析失败'},
          ],
        }),
        '坏源：解析失败',
      );
      expect(SourceUtils.firstImportFailure({}), isNull);
    });
  });

  group('调试阶段归类', () {
    test('字段映射到阶段', () {
      expect(SourceUtils.stageOfField('search'), '搜索');
      expect(SourceUtils.stageOfField('explore'), '发现');
      expect(SourceUtils.stageOfField('info'), '详情');
      expect(SourceUtils.stageOfField('toc'), '目录');
      expect(SourceUtils.stageOfField('content'), '正文');
      expect(SourceUtils.stageOfField('ruleSearch.name'), '规则完整性');
      expect(SourceUtils.stageOfField('bookSourceUrl'), '基本信息');
      expect(SourceUtils.stageOfField(''), '其他');
      expect(SourceUtils.stageOfField('whatever'), '其他');
    });

    test('阶段排序稳定', () {
      expect(SourceUtils.stageRank('基本信息'), lessThan(SourceUtils.stageRank('搜索')));
      expect(SourceUtils.stageRank('正文'), lessThan(SourceUtils.stageRank('其他')));
      expect(SourceUtils.stageRank('未知'), SourceUtils.stageOrder.length);
    });

    test('未命中判定', () {
      expect(SourceUtils.isMiss('error', '随便'), isTrue);
      expect(SourceUtils.isMiss('info', '搜索失败: timeout'), isTrue);
      expect(SourceUtils.isMiss('info', '搜索无结果'), isTrue);
      expect(SourceUtils.isMiss('info', 'text 为空'), isTrue);
      expect(SourceUtils.isMiss('warning', '可能无法解析列表'), isTrue);
      expect(SourceUtils.isMiss('info', '搜索成功，命中 3 条'), isFalse);
    });

    test('命中数提取', () {
      expect(SourceUtils.hitCountOf('搜索成功，命中 12 条'), 12);
      expect(SourceUtils.hitCountOf('目录解析成功，共 340 章'), 340);
      expect(SourceUtils.hitCountOf('正文解析成功(1024 字)'), 1024);
      expect(SourceUtils.hitCountOf('没有任何数字'), isNull);
    });
  });

  group('时间格式化', () {
    test('timeOfDay 输出本地时分秒', () {
      final iso = DateTime(2026, 11, 18, 9, 5, 3).toIso8601String();
      expect(SourceUtils.timeOfDay(iso), '09:05:03');
    });

    test('非法输入返回空/占位', () {
      expect(SourceUtils.timeOfDay(null), '');
      expect(SourceUtils.timeOfDay('x'), '');
      expect(SourceUtils.dateOf(null), '—');
      expect(SourceUtils.dateOf('x'), '—');
    });

    test('dateOf 输出日期', () {
      final iso = DateTime(2026, 1, 2, 3, 4, 5).toIso8601String();
      expect(SourceUtils.dateOf(iso), '2026-01-02');
    });
  });
}
