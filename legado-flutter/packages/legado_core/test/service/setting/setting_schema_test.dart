import 'package:legado_core/src/service/setting/setting_schema.dart';
import 'package:test/test.dart';

import 'support/ui_fixture.dart';

void main() {
  const schema = defaultSettingsSchema;
  final items = <SettingItem>[
    for (final section in schema.sections) ...section.items,
  ];

  group('与 UI 的契约', () {
    test('Schema JSON 与 Flutter fixture 逐字段一致', () {
      // fixture 是 UI 单测的基准，等于「UI 已冻结的结构」。
      // 这里一旦失败，说明内核下发的结构已和 UI 的消费方式对不上。
      expect(schema.toJson(), uiFixture('settings_schema.json'));
    });

    test('页面名与 UI 的三个页面一致', () {
      expect(schema.pages, <String>['read', 'theme', 'general']);
      // UI 用 sectionsForPage 过滤，未知页面必须给空列表而不是抛异常。
      expect(schema.sectionsForPage('nope'), isEmpty);
    });

    test('每个分组的 page 都在 pages 里', () {
      for (final section in schema.sections) {
        expect(schema.pages, contains(section.page), reason: section.key);
      }
    });

    test('Reader 用到的 11 个键都能在 Schema 中找到', () {
      const keys = <String>[
        'reader.fontSize',
        'reader.lineHeight',
        'reader.paragraphSpacing',
        'reader.indentFirstLine',
        'reader.paddingHorizontal',
        'reader.paddingVertical',
        'reader.pageTurn',
        'reader.theme',
        'reader.showPageNumber',
        'reader.textJustify',
        'general.promptAddToShelf',
        // 阅读器的自动缓存读这三项。
        'cache.autoCache',
        'cache.preDownloadNum',
        'cache.expireDays',
      ];
      for (final key in keys) {
        expect(schema.itemByKey(key), isNotNull, reason: key);
      }
    });
  });

  group('结构完整性', () {
    test('5 个分组按页面分布', () {
      expect(schema.sections.length, 5);
      expect(
        schema.sectionsForPage('read').map((section) => section.key),
        <String>['typography', 'paging'],
      );
      expect(schema.sectionsForPage('theme').single.key, 'background');
      expect(
        schema.sectionsForPage('general').map((section) => section.key),
        <String>['behavior', 'cache'],
      );
    });

    test('共 14 个设置项，key 全局唯一', () {
      expect(items.length, 14);
      expect(items.map((item) => item.key).toSet().length, items.length);
      for (final item in items) {
        expect(schema.itemByKey(item.key), same(item));
      }
    });

    test('每项都有非空 key/title', () {
      for (final item in items) {
        expect(item.key.trim(), isNotEmpty);
        expect(item.title.trim(), isNotEmpty);
      }
      for (final section in schema.sections) {
        expect(section.title.trim(), isNotEmpty);
      }
    });
  });

  group('默认值能被 kind 解释', () {
    test('switch 的默认值是 bool', () {
      final switches = items.where(
        (item) => item.kind == SettingKind.switchToggle,
      );
      expect(switches, isNotEmpty);
      for (final item in switches) {
        expect(item.defaultValue, isA<bool>(), reason: item.key);
      }
    });

    test('slider/number 的默认值是数字且落在区间内', () {
      for (final item in items.where(
        (item) =>
            item.kind == SettingKind.slider ||
            item.kind == SettingKind.number,
      )) {
        final value = item.defaultValue;
        expect(value, isA<num>(), reason: item.key);
        final number = (value as num).toDouble();
        if (item.min != null) {
          expect(number, greaterThanOrEqualTo(item.min!), reason: item.key);
        }
        if (item.max != null) {
          expect(number, lessThanOrEqualTo(item.max!), reason: item.key);
        }
      }
    });

    test('slider 必须有 max，step 为正且小于区间', () {
      for (final item in items.where(
        (item) => item.kind == SettingKind.slider,
      )) {
        expect(item.max, isNotNull, reason: item.key);
        expect(item.step, isNotNull, reason: item.key);
        expect(item.step! > 0, isTrue, reason: item.key);
        final min = (item.min ?? 0).toDouble();
        expect(item.max! > min, isTrue, reason: item.key);
        expect(item.step! <= (item.max! - min), isTrue, reason: item.key);
      }
    });

    test('select 的默认值在 options 内，option 值唯一且非空', () {
      for (final item in items.where(
        (item) => item.kind == SettingKind.select,
      )) {
        final options = item.options;
        expect(options, isNotNull, reason: item.key);
        expect(options, isNotEmpty, reason: item.key);
        final values = options!.map((option) => option.value).toList();
        expect(values.toSet().length, values.length, reason: item.key);
        for (final option in options) {
          expect(option.value.trim(), isNotEmpty, reason: item.key);
          expect(option.label.trim(), isNotEmpty, reason: item.key);
        }
        expect(values, contains(item.defaultValue), reason: item.key);
      }
    });
  });

  group('序列化', () {
    test('defaultRaw 与 UI 的字符串形态一致', () {
      expect(schema.itemByKey('reader.fontSize')!.defaultRaw, '20');
      expect(schema.itemByKey('reader.lineHeight')!.defaultRaw, '1.8');
      expect(schema.itemByKey('reader.indentFirstLine')!.defaultRaw, 'true');
      expect(schema.itemByKey('general.promptAddToShelf')!.defaultRaw, 'false');
      expect(schema.itemByKey('reader.pageTurn')!.defaultRaw, 'cover');
    });

    test('null 字段不写进 JSON（UI 靠缺失判断无上限）', () {
      final spacing = schema.itemByKey('reader.paragraphSpacing')!.toJson();
      // min 缺失 = 沿用 UI 缺省的 0；desc 缺失 = 不占一行说明。
      expect(spacing.containsKey('min'), isFalse);
      expect(spacing.containsKey('desc'), isFalse);
      // unit 有值就必须写出去：fixture（UI 已冻结的契约）里这一项是 "px"。
      expect(spacing['unit'], 'px');

      final toggle = schema.itemByKey('reader.indentFirstLine')!.toJson();
      expect(toggle.containsKey('min'), isFalse);
      expect(toggle.containsKey('max'), isFalse);
      expect(toggle.containsKey('step'), isFalse);
      expect(toggle.containsKey('unit'), isFalse);
      expect(toggle.containsKey('options'), isFalse);
    });

    test('kind 的线上名与 UI 的 wire 字符串一致', () {
      expect(
        SettingKind.values.map((kind) => kind.wire).toSet(),
        <String>{'switch', 'slider', 'select', 'number', 'text'},
      );
      expect(SettingKind.tryParse('switch'), SettingKind.switchToggle);
      expect(SettingKind.tryParse('color'), isNull);
      expect(SettingKind.tryParse(7), isNull);
    });

    test('toJson 可重复调用且结果稳定', () {
      expect(schema.toJson(), schema.toJson());
      // 常量 Schema 不能被序列化「改坏」：二次读取的 key 集合仍完整。
      expect(schema.itemByKey('reader.fontSize'), isNotNull);
    });
  });
}
