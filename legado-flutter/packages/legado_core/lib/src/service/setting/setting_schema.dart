/// 设置项的控件类型。
///
/// 线上表示（JSON 的 `kind`）必须与 Flutter UI 的 `SettingsKind` 一字不差：
/// UI 解析不到的 kind 会降级成只读行而不是报错，所以拼错一个字母的后果是
/// 「设置项还在，但点不动」，页面上看不出任何异常。
enum SettingKind {
  /// 开关。UI 写 `true`/`false`。
  switchToggle('switch'),

  /// 滑块。必须有 `min`/`max`（`max` 缺失时 UI 退化成只读行）。
  slider('slider'),

  /// 下拉。`default` 与取值都必须落在 `options` 里。
  select('select'),

  /// 数字输入框。
  number('number'),

  /// 文本输入框。
  text('text');

  const SettingKind(this.wire);

  /// JSON 里的字符串。
  final String wire;

  /// 解析线上值。未知值返回 null，由调用方决定降级策略。
  static SettingKind? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final kind in values) {
      if (kind.wire == raw) return kind;
    }
    return null;
  }
}

/// 数值 → 字符串，用于 Values（值一律字符串）。
///
/// 整数不带小数点（`20` 而不是 `20.0`），小数去掉浮点运算留下的尾数
/// （`1.8000000000000003` → `1.8`）。与 UI 的 `settingsNumberText` 同一算法，
/// 否则输入框里会出现一串无意义的小数位。
String settingNumberText(num value) {
  final number = value.toDouble();
  if (!number.isFinite) return '0';
  if (number == number.roundToDouble()) return number.toStringAsFixed(0);
  var text = number.toStringAsFixed(4);
  while (text.contains('.') && text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text;
}

/// 下拉项。
///
/// 线上字段是 [label]（不是 `title`）：UI 的 `SettingsOption.fromJson` 只读
/// `value`/`label`，写成 `title` 会渲染出空白文字。
class SettingOption {
  const SettingOption({required this.value, required this.label});

  final String value;
  final String label;

  Map<String, Object?> toJson() => <String, Object?>{
    'value': value,
    'label': label,
  };
}

/// 一个设置项。
///
/// [defaultValue] 保留强类型（bool/num/String），不是字符串：UI 用它判断
/// 开关的兜底状态、滑块的 fallback 位置，并据此算出 [defaultRaw]。
class SettingItem {
  const SettingItem({
    required this.key,
    required this.kind,
    required this.title,
    required this.defaultValue,
    this.desc,
    this.options,
    this.min,
    this.max,
    this.step,
    this.unit,
  });

  final String key;
  final SettingKind kind;
  final String title;
  final String? desc;
  final Object defaultValue;
  final List<SettingOption>? options;

  /// 区间下限；null 表示沿用 UI 的缺省 0。
  final num? min;

  /// 区间上限；null（UI 里等价于 0）表示没有上限。
  final num? max;

  /// 步长；null 表示不吸附到整数格。
  final num? step;

  final String? unit;

  /// 默认值的字符串形态，与 Schema 下发给 UI 的值同构。
  String get defaultRaw {
    final value = defaultValue;
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) return settingNumberText(value);
    return '$value';
  }

  /// 只有非空字段才写进 JSON。
  ///
  /// UI 对缺失字段有明确缺省（`min`→0、`max`→0、`step`→1），把 `"min": 0`
  /// 也写出去反而会让「0 表示无上限」的约定失效。
  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'kind': kind.wire,
    'title': title,
    if (desc != null) 'desc': desc,
    'default': defaultValue,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (step != null) 'step': step,
    if (unit != null) 'unit': unit,
    if (options != null)
      'options': <Object?>[for (final option in options!) option.toJson()],
  };
}

/// 一个分组。UI 按 [page] 过滤后整块渲染，标题与说明来自这里。
class SettingSection {
  const SettingSection({
    required this.key,
    required this.page,
    required this.title,
    required this.items,
    this.desc,
  });

  final String key;

  /// 所属页面：`read` / `theme` / `general`，必须出现在 [SettingsSchema.pages] 里。
  final String page;
  final String title;
  final String? desc;
  final List<SettingItem> items;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'page': page,
    'title': title,
    if (desc != null) 'desc': desc,
    'items': <Object?>[for (final item in items) item.toJson()],
  };
}

/// 设置页结构，`Settings.Schema` 的返回体。
class SettingsSchema {
  const SettingsSchema({
    required this.version,
    required this.pages,
    required this.sections,
  });

  /// 结构版本，UI 只在展示/排查时用到；结构不兼容时递增。
  final int version;

  /// 页面顺序。UI 目前只按名字取分组，顺序留给后续导航用。
  final List<String> pages;
  final List<SettingSection> sections;

  List<SettingSection> sectionsForPage(String page) => <SettingSection>[
    for (final section in sections)
      if (section.page == page) section,
  ];

  SettingItem? itemByKey(String key) {
    for (final section in sections) {
      for (final item in section.items) {
        if (item.key == key) return item;
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'pages': pages,
    'sections': <Object?>[for (final section in sections) section.toJson()],
  };
}

/// 内核内置的设置结构。
///
/// 内容与 `app/test/fixtures/settings_schema.json` 逐字段对齐——那份 fixture 是
/// Flutter UI 的单测基准，也就等于「UI 已冻结的契约」。改这里必须同步改 fixture
/// 与 UI 的单测，否则 `settings_schema_test.dart` 会直接失败提醒。
///
/// 只收 UI 三个页面（`read`/`theme`/`general`）实际渲染的项，原版 Kotlin 的
/// 两百多个偏好项没有全搬：Schema 驱动渲染，多搬一项就等于多一个没人认领的面板。
/// `search` 页不出现在设置中心，只给搜索页持久化「精确搜索 / 搜索范围」两个条件：
/// 设置服务只认 Schema 里的 key，未知 key 会被写路径静默丢弃。
const SettingsSchema defaultSettingsSchema = SettingsSchema(
  version: 3,
  pages: <String>['read', 'theme', 'general', 'search'],
  sections: <SettingSection>[
    SettingSection(
      key: 'typography',
      page: 'read',
      title: '排版',
      desc: '改动立即作用于阅读器，并重新分页',
      items: <SettingItem>[
        SettingItem(
          key: 'reader.fontSize',
          kind: SettingKind.slider,
          title: '字号',
          defaultValue: 20,
          min: 12,
          max: 40,
          step: 1,
          unit: 'px',
        ),
        SettingItem(
          key: 'reader.lineHeight',
          kind: SettingKind.slider,
          title: '行距',
          desc: '行高倍数，中文正文 1.7~1.9 较透气',
          defaultValue: 1.8,
          min: 1,
          max: 3,
          step: 0.1,
          unit: '倍',
        ),
        SettingItem(
          key: 'reader.paragraphSpacing',
          kind: SettingKind.slider,
          title: '段间距',
          defaultValue: 10,
          max: 40,
          step: 1,
          unit: 'px',
        ),
        SettingItem(
          key: 'reader.indentFirstLine',
          kind: SettingKind.switchToggle,
          title: '段首缩进',
          desc: '两字宽的全角缩进',
          defaultValue: true,
        ),
        SettingItem(
          key: 'reader.paddingHorizontal',
          kind: SettingKind.slider,
          title: '左右页边距',
          defaultValue: 20,
          max: 80,
          step: 2,
          unit: 'px',
        ),
        SettingItem(
          key: 'reader.paddingVertical',
          kind: SettingKind.slider,
          title: '上下页边距',
          defaultValue: 12,
          max: 80,
          step: 2,
          unit: 'px',
        ),
        SettingItem(
          key: 'reader.textJustify',
          kind: SettingKind.switchToggle,
          title: '两端对齐',
          desc: '关闭后左对齐，右侧留自然参差',
          defaultValue: true,
        ),
        SettingItem(
          key: 'reader.showPageNumber',
          kind: SettingKind.switchToggle,
          title: '显示页码',
          desc: '页脚同时显示章节名',
          defaultValue: true,
        ),
      ],
    ),
    SettingSection(
      key: 'paging',
      page: 'read',
      title: '翻页',
      items: <SettingItem>[
        SettingItem(
          key: 'reader.pageTurn',
          kind: SettingKind.select,
          title: '翻页动画',
          defaultValue: 'cover',
          options: <SettingOption>[
            SettingOption(value: 'cover', label: '覆盖'),
            SettingOption(value: 'slide', label: '滑动'),
            SettingOption(value: 'simulation', label: '仿真'),
            SettingOption(value: 'scroll', label: '滚动'),
            SettingOption(value: 'none', label: '无动画'),
          ],
        ),
      ],
    ),
    SettingSection(
      key: 'readAloud',
      page: 'read',
      title: '朗读',
      desc: '使用系统自带的文字转语音引擎；1.0 倍为正常语速与原声',
      items: <SettingItem>[
        SettingItem(
          key: 'reader.ttsSpeed',
          kind: SettingKind.slider,
          title: '朗读语速',
          desc: '低于 1.0 变慢，高于 1.0 变快；下一句生效',
          defaultValue: 1.0,
          min: 0.4,
          max: 2.0,
          step: 0.1,
          unit: '倍',
        ),
        SettingItem(
          key: 'reader.ttsPitch',
          kind: SettingKind.slider,
          title: '朗读音调',
          desc: '1.0 为引擎原声，调低调高可换听感；部分引擎不支持',
          defaultValue: 1.0,
          min: 0.5,
          max: 2.0,
          step: 0.1,
        ),
        SettingItem(
          key: 'reader.ttsAutoPage',
          kind: SettingKind.switchToggle,
          title: '读完整页自动翻页',
          desc: '关闭后读完当前页停下，不再自动续读',
          defaultValue: true,
        ),
      ],
    ),
    SettingSection(
      key: 'background',
      page: 'theme',
      title: '背景',
      desc: '文字颜色随背景自动切换，夜间模式不会出现黑底黑字',
      items: <SettingItem>[
        SettingItem(
          key: 'reader.theme',
          kind: SettingKind.select,
          title: '阅读背景',
          defaultValue: 'paper',
          options: <SettingOption>[
            SettingOption(value: 'paper', label: '纸黄'),
            SettingOption(value: 'white', label: '米白'),
            SettingOption(value: 'green', label: '浅绿'),
            SettingOption(value: 'gray', label: '浅灰'),
            SettingOption(value: 'night', label: '夜间'),
          ],
        ),
      ],
    ),
    SettingSection(
      key: 'behavior',
      page: 'general',
      title: '行为',
      items: <SettingItem>[
        SettingItem(
          key: 'general.promptAddToShelf',
          kind: SettingKind.switchToggle,
          title: '退出时询问加入书架',
          desc: '从搜索/发现点开的书只管试读，默认不打扰；打开后退出时会问一次',
          defaultValue: false,
        ),
      ],
    ),
    SettingSection(
      key: 'cache',
      page: 'general',
      title: '缓存',
      desc: '读到哪存到哪，预取的章节断网也能看',
      items: <SettingItem>[
        SettingItem(
          key: 'cache.autoCache',
          kind: SettingKind.switchToggle,
          title: '自动缓存',
          desc: '读完一章自动存入缓存，并按下面的数量往后预取',
          defaultValue: true,
        ),
        SettingItem(
          key: 'cache.preDownloadNum',
          kind: SettingKind.slider,
          title: '预取章节数',
          desc: '当前章之后自动缓存多少章（0 表示只缓存读过的章）',
          defaultValue: 10,
          max: 50,
          step: 1,
          unit: '章',
        ),
        SettingItem(
          key: 'cache.expireDays',
          kind: SettingKind.slider,
          title: '自动缓存有效期',
          desc: '阅读时自动缓存（含预取）多少天后过期；0 表示永久保留。手动缓存始终永久保留',
          defaultValue: 2,
          max: 90,
          step: 1,
          unit: '天',
        ),
      ],
    ),
    SettingSection(
      key: 'search',
      page: 'search',
      title: '搜索',
      items: <SettingItem>[
        SettingItem(
          key: 'search.precision',
          kind: SettingKind.switchToggle,
          title: '精确搜索',
          desc: '按书名/作者包含关键词过滤结果，对应原版 PreferKey.precisionSearch',
          defaultValue: false,
        ),
        SettingItem(
          key: 'search.scope',
          kind: SettingKind.text,
          title: '搜索范围',
          desc: '空=全部书源；名称::地址=单源；逗号分隔=多个分组',
          defaultValue: '',
        ),
      ],
    ),
  ],
);
