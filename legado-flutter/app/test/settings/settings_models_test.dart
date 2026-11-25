import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:legado/features/reader/reader_style.dart';
import 'package:legado/features/settings/settings_models.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final json = _fixture('settings_schema.json');
  final schema = SettingsSchema.fromJson(json);

  group('SettingsSchema', () {
    test('版本、页面与分组数量与 fixture 一致', () {
      expect(schema.version, 2);
      expect(schema.pages, <String>['read', 'theme', 'general', 'search']);
      expect(schema.sections.length, 6);
      expect(
        schema.sectionsForPage('read').map((section) => section.key),
        <String>['typography', 'paging'],
      );
      expect(
        schema.sectionsForPage('general').map((section) => section.key),
        <String>['behavior', 'cache'],
      );
      // 未知页面返回空列表，页面渲染成空态而不是抛异常。
      expect(schema.sectionsForPage('nope'), isEmpty);
    });

    test('分组标题/说明', () {
      final typography = schema.sectionsForPage('read').first;
      expect(typography.title, '排版');
      expect(typography.desc, '改动立即作用于阅读器，并重新分页');
      expect(typography.items.length, 8);
    });

    test('滑块项字段完整（min/max/step/unit）', () {
      final item = schema.itemByKey('reader.fontSize')!;
      expect(item.kind, SettingsKind.slider);
      expect(item.title, '字号');
      expect(item.desc, isNull);
      expect(item.defaultValue, 20);
      expect(item.min, 12);
      expect(item.max, 40);
      expect(item.step, 1);
      expect(item.unit, 'px');
      expect(item.hasRange, isTrue);
      expect(item.defaultRaw, '20');

      final lineHeight = schema.itemByKey('reader.lineHeight')!;
      expect(lineHeight.step, 0.1);
      expect(lineHeight.desc, isNotNull);
      expect(lineHeight.defaultRaw, '1.8');
    });

    test('omitempty：缺失的 min 归 0、缺失的 step 归 1', () {
      final item = schema.itemByKey('reader.paragraphSpacing')!;
      expect(item.min, 0);
      expect(item.max, 40);
      expect(item.step, 1);

      // max 也缺失时（0 表示无上限）滑块没有有效区间。
      final bare = SettingsItem.fromJson(<String, Object?>{
        'key': 'x.y',
        'kind': 'slider',
        'title': '无区间',
      });
      expect(bare.min, 0);
      expect(bare.max, 0);
      expect(bare.step, 1);
      expect(bare.hasRange, isFalse);
    });

    test('开关项默认值保持强类型 bool', () {
      final item = schema.itemByKey('reader.indentFirstLine')!;
      expect(item.kind, SettingsKind.toggle);
      expect(item.defaultValue, isA<bool>());
      expect(item.defaultValue, isTrue);
      expect(item.desc, '两字宽的全角缩进');
      expect(item.defaultRaw, 'true');
    });

    test('下拉项带 options，顺序与 label 原样保留', () {
      final item = schema.itemByKey('reader.pageTurn')!;
      expect(item.kind, SettingsKind.select);
      expect(item.defaultValue, 'cover');
      expect(item.options.length, 5);
      expect(item.options.first.value, 'cover');
      expect(item.options.first.label, '覆盖');
      expect(item.options.last.label, '无动画');

      final theme = schema.itemByKey('reader.theme')!;
      expect(theme.options.map((option) => option.value), <String>[
        'paper',
        'white',
        'green',
        'gray',
        'night',
      ]);
    });

    test('未知 kind 降级为 unknown 而不是抛异常', () {
      final item = SettingsItem.fromJson(<String, Object?>{
        'key': 'reader.future',
        'kind': 'color',
        'title': '未来控件',
        'default': '#fff',
      });
      expect(item.kind, SettingsKind.unknown);
      expect(item.defaultValue, '#fff');
      expect(item.title, '未来控件');
    });

    test('脏 JSON 全部走安全默认值', () {
      expect(SettingsSchema.fromJson(null).sections, isEmpty);
      expect(SettingsSchema.fromJson('boom').version, 0);
      final broken = SettingsSchema.fromJson(<String, Object?>{
        'version': 'one',
        'pages': 'read',
        'sections': <Object?>[null, 'x'],
      });
      expect(broken.version, 0);
      expect(broken.pages, isEmpty);
      expect(broken.sections.length, 2);
      expect(broken.sections.first.items, isEmpty);

      final item = SettingsItem.fromJson(<String, Object?>{
        'key': 42,
        'kind': 7,
        'min': 'bad',
        'step': 0,
      });
      expect(item.key, '42');
      expect(item.kind, SettingsKind.unknown);
      expect(item.min, 0);
      expect(item.step, 1);
    });
  });

  group('取值助手', () {
    test('settingsDouble 容错', () {
      expect(settingsDouble('1.8', 0), 1.8);
      expect(settingsDouble(3, 0), 3);
      expect(settingsDouble(' 26 ', 0), 26);
      expect(settingsDouble('abc', 1.5), 1.5);
      expect(settingsDouble(null, 2), 2);
    });

    test('settingsBool 容错', () {
      expect(settingsBool('true', false), isTrue);
      expect(settingsBool('0', true), isFalse);
      expect(settingsBool(1, false), isTrue);
      expect(settingsBool(null, true), isTrue);
      expect(settingsBool('随便', false), isFalse);
    });

    test('settingsNumberText 去掉多余小数位', () {
      expect(settingsNumberText(20), '20');
      expect(settingsNumberText(1.8), '1.8');
      expect(settingsNumberText(1.8000000001), '1.8');
      expect(settingsNumberText(0), '0');
    });
  });

  group('ReaderTheme', () {
    test('顺序与 ReaderBackground.presets 对齐', () {
      expect(
        ReaderTheme.presets.map((theme) => theme.background),
        ReaderBackground.presets,
      );
      expect(ReaderTheme.presets.map((theme) => theme.value), <String>[
        'paper',
        'white',
        'green',
        'gray',
        'night',
      ]);
    });

    test('byValue 命中与兜底', () {
      final night = ReaderTheme.byValue('night');
      expect(night.value, 'night');
      expect(night.background.dark, isTrue);
      expect(night.label, '夜间');
      expect(ReaderTheme.byValue('nope'), ReaderTheme.presets.first);
      expect(ReaderTheme.byValue(null), ReaderTheme.presets.first);
    });
  });

  group('ReaderConfig', () {
    test('Values 字符串解析结果与 Settings.Reader fixture 一致', () {
      final values = _fixture('settings_values.json').map(
        (key, value) => MapEntry(key, '$value'),
      );
      final config = ReaderConfig.fromValues(values);
      expect(config.toJson(), _fixture('settings_reader.json'));
      expect(config.background.value, 'paper');
    });

    test('缺项/脏值回到与 Schema 一致的默认值', () {
      const config = ReaderConfig();
      expect(config.fontSize, 20);
      expect(config.lineHeight, 1.8);
      expect(config.indentFirstLine, isTrue);
      expect(config.pageTurn, 'cover');

      final broken = ReaderConfig.fromValues(<String, String>{
        'reader.fontSize': 'huge',
        'reader.lineHeight': '',
        'reader.indentFirstLine': 'maybe',
        'reader.theme': '',
      });
      expect(broken.fontSize, 20);
      expect(broken.lineHeight, 1.8);
      expect(broken.indentFirstLine, isTrue);
      expect(broken.theme, 'paper');
      expect(ReaderConfig.fromJson(null).fontSize, 20);
    });
  });
}
