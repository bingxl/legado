import 'package:flutter/foundation.dart' show immutable;

import '../reader/reader_style.dart';

/// 控件类型。Schema 由 Go 侧演进，未来可能加新 kind，
/// 因此解析未知值一律降级成 [unknown]（UI 渲染为只读文本），而不是抛异常。
enum SettingsKind {
  toggle('switch'),
  slider('slider'),
  select('select'),
  number('number'),
  text('text'),
  unknown('');

  const SettingsKind(this.wire);

  /// 线上（JSON）里的名字。
  final String wire;

  static SettingsKind parse(Object? raw) {
    final name = raw is String ? raw : '';
    for (final kind in values) {
      if (kind != unknown && kind.wire == name) return kind;
    }
    return unknown;
  }
}

/// 从 JSON 里安全取数：后端可能给 int/num/字符串，缺失时用 [fallback]。
double settingsDouble(Object? value, double fallback) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? fallback;
  return fallback;
}

/// 字符串值转 bool。core 的 Values 全是字符串，"true"/"1" 都当开。
bool settingsBool(Object? value, bool fallback) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    switch (value.trim().toLowerCase()) {
      case 'true':
      case '1':
      case 'on':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'off':
      case 'no':
        return false;
    }
  }
  return fallback;
}

/// 数值转展示/回传用文本：整数不带小数点，小数去掉多余的 0。
/// 服务端 Update 收字符串，滑块必须回传「26」而不是「26.0」。
String settingsNumberText(double value) {
  if (!value.isFinite) return '0';
  if (value == value.roundToDouble()) return value.toStringAsFixed(0);
  var text = value.toStringAsFixed(4);
  while (text.contains('.') && text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

@immutable
class SettingsOption {
  const SettingsOption({required this.value, required this.label});

  final String value;
  final String label;

  factory SettingsOption.fromJson(Object? json) {
    if (json is! Map) {
      return const SettingsOption(value: '', label: '');
    }
    final value = '${json['value'] ?? ''}';
    final label = '${json['label'] ?? ''}'.trim();
    return SettingsOption(value: value, label: label.isEmpty ? value : label);
  }
}

@immutable
class SettingsItem {
  const SettingsItem({
    required this.key,
    required this.kind,
    required this.title,
    this.desc,
    this.defaultValue,
    this.min = 0,
    this.max = 0,
    this.step = 1,
    this.unit,
    this.options = const <SettingsOption>[],
  });

  final String key;
  final SettingsKind kind;
  final String title;
  final String? desc;

  /// 强类型的默认值（bool/num/String），不是字符串。
  final Object? defaultValue;

  /// 区间。Go 的 json tag 带 omitempty：值为 0 时字段整个缺失，
  /// 因此 min 缺省 0、max 缺省 0（0 表示无上限）、step 缺省 1。
  final double min;
  final double max;
  final double step;

  final String? unit;
  final List<SettingsOption> options;

  /// 是否有可滑动的有效区间。max 缺失/不大于 min 时滑块无意义。
  bool get hasRange => max > min;

  /// 默认值转成 Values 里的字符串形态，用于本地兜底显示。
  String get defaultRaw {
    final d = defaultValue;
    if (d == null) return '';
    if (d is bool) return d ? 'true' : 'false';
    if (d is num) return settingsNumberText(d.toDouble());
    return '$d';
  }

  factory SettingsItem.fromJson(Object? json) {
    if (json is! Map) {
      return const SettingsItem(
        key: '',
        kind: SettingsKind.unknown,
        title: '',
      );
    }
    final rawOptions = json['options'];
    final options = <SettingsOption>[
      if (rawOptions is List)
        for (final option in rawOptions) SettingsOption.fromJson(option),
    ];
    final rawStep = settingsDouble(json['step'], 1);
    return SettingsItem(
      key: '${json['key'] ?? ''}',
      kind: SettingsKind.parse(json['kind']),
      title: '${json['title'] ?? json['key'] ?? ''}',
      desc: _nullableText(json['desc']),
      defaultValue: json['default'],
      min: settingsDouble(json['min'], 0),
      max: settingsDouble(json['max'], 0),
      step: rawStep <= 0 ? 1 : rawStep,
      unit: _nullableText(json['unit']),
      options: options,
    );
  }
}

@immutable
class SettingsSection {
  const SettingsSection({
    required this.key,
    required this.page,
    required this.title,
    this.desc,
    this.items = const <SettingsItem>[],
  });

  final String key;
  final String page;
  final String title;
  final String? desc;
  final List<SettingsItem> items;

  factory SettingsSection.fromJson(Object? json) {
    if (json is! Map) {
      return const SettingsSection(key: '', page: '', title: '');
    }
    final rawItems = json['items'];
    return SettingsSection(
      key: '${json['key'] ?? ''}',
      page: '${json['page'] ?? ''}',
      title: '${json['title'] ?? ''}',
      desc: _nullableText(json['desc']),
      items: <SettingsItem>[
        if (rawItems is List)
          for (final item in rawItems) SettingsItem.fromJson(item),
      ],
    );
  }
}

/// 设置页结构。Schema 拉不到时退化成空结构，页面仍能渲染入口与错误态。
@immutable
class SettingsSchema {
  const SettingsSchema({
    this.version = 0,
    this.pages = const <String>[],
    this.sections = const <SettingsSection>[],
  });

  final int version;
  final List<String> pages;
  final List<SettingsSection> sections;

  List<SettingsSection> sectionsForPage(String page) => <SettingsSection>[
    for (final section in sections)
      if (section.page == page) section,
  ];

  SettingsItem? itemByKey(String key) {
    for (final section in sections) {
      for (final item in section.items) {
        if (item.key == key) return item;
      }
    }
    return null;
  }

  factory SettingsSchema.fromJson(Object? json) {
    if (json is! Map) return const SettingsSchema();
    final rawPages = json['pages'];
    final rawSections = json['sections'];
    return SettingsSchema(
      version: json['version'] is num
          ? (json['version'] as num).toInt()
          : 0,
      pages: <String>[
        if (rawPages is List)
          for (final page in rawPages)
            if (page is String) page,
      ],
      sections: <SettingsSection>[
        if (rawSections is List)
          for (final section in rawSections) SettingsSection.fromJson(section),
      ],
    );
  }
}

/// 阅读背景选项。顺序与 [ReaderBackground.presets] 一一对应，
/// 颜色/文字色只从那里取，避免设置页和阅读器各有一套色板。
@immutable
class ReaderTheme {
  const ReaderTheme({required this.value, required this.background});

  /// Values 里 `reader.theme` 的取值。
  final String value;
  final ReaderBackground background;

  String get label => background.name;

  static const presets = <ReaderTheme>[
    ReaderTheme(value: 'paper', background: ReaderBackground.paper),
    ReaderTheme(value: 'white', background: ReaderBackground.white),
    ReaderTheme(value: 'green', background: ReaderBackground.green),
    ReaderTheme(value: 'gray', background: ReaderBackground.gray),
    ReaderTheme(value: 'night', background: ReaderBackground.night),
  ];

  /// 未知取值退回纸黄：宁可显示默认背景，也不要让阅读器炸掉。
  static ReaderTheme byValue(String? value) {
    for (final preset in presets) {
      if (preset.value == value) return preset;
    }
    return presets.first;
  }
}

/// 强类型阅读配置。
///
/// 字段与 `Settings.Reader` 返回一一对应；所有兜底值都与 Schema 默认值一致，
/// 因此脏数据只会让某一项回到默认，不会在阅读器里抛异常。
@immutable
class ReaderConfig {
  const ReaderConfig({
    this.fontSize = 20,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 10,
    this.indentFirstLine = true,
    this.paddingHorizontal = 20,
    this.paddingVertical = 12,
    this.pageTurn = 'cover',
    this.theme = 'paper',
    this.showPageNumber = true,
    this.textJustify = true,
    this.promptAddToShelf = false,
  });

  final double fontSize;
  final double lineHeight;
  final double paragraphSpacing;
  final bool indentFirstLine;
  final double paddingHorizontal;
  final double paddingVertical;
  final String pageTurn;
  final String theme;
  final bool showPageNumber;
  final bool textJustify;
  final bool promptAddToShelf;

  ReaderTheme get background => ReaderTheme.byValue(theme);

  /// Values（全字符串）→ 强类型。
  factory ReaderConfig.fromValues(Map<String, String> raw) {
    return ReaderConfig(
      fontSize: settingsDouble(raw['reader.fontSize'], 20),
      lineHeight: settingsDouble(raw['reader.lineHeight'], 1.8),
      paragraphSpacing: settingsDouble(raw['reader.paragraphSpacing'], 10),
      indentFirstLine: settingsBool(raw['reader.indentFirstLine'], true),
      paddingHorizontal: settingsDouble(raw['reader.paddingHorizontal'], 20),
      paddingVertical: settingsDouble(raw['reader.paddingVertical'], 12),
      pageTurn: _textOr(raw['reader.pageTurn'], 'cover'),
      theme: _textOr(raw['reader.theme'], 'paper'),
      showPageNumber: settingsBool(raw['reader.showPageNumber'], true),
      textJustify: settingsBool(raw['reader.textJustify'], true),
      promptAddToShelf: settingsBool(raw['general.promptAddToShelf'], false),
    );
  }

  /// `Settings.Reader` 的强类型 JSON → 强类型。
  factory ReaderConfig.fromJson(Object? json) {
    if (json is! Map) return const ReaderConfig();
    return ReaderConfig(
      fontSize: settingsDouble(json['fontSize'], 20),
      lineHeight: settingsDouble(json['lineHeight'], 1.8),
      paragraphSpacing: settingsDouble(json['paragraphSpacing'], 10),
      indentFirstLine: settingsBool(json['indentFirstLine'], true),
      paddingHorizontal: settingsDouble(json['paddingHorizontal'], 20),
      paddingVertical: settingsDouble(json['paddingVertical'], 12),
      pageTurn: _textOr(json['pageTurn'], 'cover'),
      theme: _textOr(json['theme'], 'paper'),
      showPageNumber: settingsBool(json['showPageNumber'], true),
      textJustify: settingsBool(json['textJustify'], true),
      promptAddToShelf: settingsBool(json['promptAddToShelf'], false),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'fontSize': fontSize,
    'lineHeight': lineHeight,
    'paragraphSpacing': paragraphSpacing,
    'indentFirstLine': indentFirstLine,
    'paddingHorizontal': paddingHorizontal,
    'paddingVertical': paddingVertical,
    'pageTurn': pageTurn,
    'theme': theme,
    'showPageNumber': showPageNumber,
    'textJustify': textJustify,
    'promptAddToShelf': promptAddToShelf,
  };
}

String? _nullableText(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  return text.isEmpty ? null : text;
}

String _textOr(Object? value, String fallback) {
  final text = _nullableText(value);
  return text ?? fallback;
}
