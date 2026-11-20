/// 强类型阅读配置，`Settings.Reader` 的返回体。
///
/// **容错是硬要求**：阅读器每个页面都要读它，任何一处解析失败都不能抛——
/// 一个脏的 `reader.fontSize` 不该让整本书打不开。因此：
///   * 缺失字段 → 默认值；
///   * 解析失败（空串、`20px`、`NaN`、`Infinity`）→ 默认值；
///   * 数值越界 → 钳到区间边界（而不是丢回默认值，用户的意图更接近边界）；
///   * 枚举值不认识（schema 演进、旧客户端）→ 默认枚举。
///
/// 区间与 [defaultSettingsSchema] 里对应 item 的 `min`/`max` 一致，
/// 默认值与 Schema 的 `default` 一致——两边漂移会让「设置页显示 20、
/// 阅读器按 22 排版」这种问题极难排查。
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

  /// 翻页动画：`cover` / `slide` / `simulation` / `scroll` / `none`，
  /// 对应 Kotlin 的 `PageAnim`（0–4）。
  final String pageTurn;

  /// 阅读背景：`paper` / `white` / `green` / `gray` / `night`。
  final String theme;
  final bool showPageNumber;
  final bool textJustify;
  final bool promptAddToShelf;

  /// 字号区间，与 Schema 的 `reader.fontSize` 对齐。
  static const minFontSize = 12.0;
  static const maxFontSize = 40.0;

  static const minLineHeight = 1.0;
  static const maxLineHeight = 3.0;

  static const maxParagraphSpacing = 40.0;
  static const maxPadding = 80.0;

  /// Kotlin `PageAnim` 的全部取值。
  static const pageTurns = <String>{
    'cover',
    'slide',
    'simulation',
    'scroll',
    'none',
  };

  /// 与 UI `ReaderTheme.presets` 的 value 一一对应。
  static const themes = <String>{'paper', 'white', 'green', 'gray', 'night'};

  /// Values（键见 Schema，值一律字符串）→ 强类型。永不抛错。
  factory ReaderConfig.fromMap(Map<String, String> values) => ReaderConfig(
    fontSize: _number(
      values['reader.fontSize'],
      fallback: 20,
      min: minFontSize,
      max: maxFontSize,
    ),
    lineHeight: _number(
      values['reader.lineHeight'],
      fallback: 1.8,
      min: minLineHeight,
      max: maxLineHeight,
    ),
    paragraphSpacing: _number(
      values['reader.paragraphSpacing'],
      fallback: 10,
      min: 0,
      max: maxParagraphSpacing,
    ),
    indentFirstLine: _flag(values['reader.indentFirstLine'], true),
    paddingHorizontal: _number(
      values['reader.paddingHorizontal'],
      fallback: 20,
      min: 0,
      max: maxPadding,
    ),
    paddingVertical: _number(
      values['reader.paddingVertical'],
      fallback: 12,
      min: 0,
      max: maxPadding,
    ),
    pageTurn: _enum(values['reader.pageTurn'], pageTurns, 'cover'),
    theme: _enum(values['reader.theme'], themes, 'paper'),
    showPageNumber: _flag(values['reader.showPageNumber'], true),
    textJustify: _flag(values['reader.textJustify'], true),
    promptAddToShelf: _flag(values['general.promptAddToShelf'], false),
  );

  /// 字段名与契约表 `ReaderConfig{...}` 完全一致，顺序也照抄，方便 CLI 肉眼对照。
  Map<String, Object?> toJson() => <String, Object?>{
    'fontSize': _wire(fontSize),
    'lineHeight': _wire(lineHeight),
    'paragraphSpacing': _wire(paragraphSpacing),
    'indentFirstLine': indentFirstLine,
    'paddingHorizontal': _wire(paddingHorizontal),
    'paddingVertical': _wire(paddingVertical),
    'pageTurn': pageTurn,
    'theme': theme,
    'showPageNumber': showPageNumber,
    'textJustify': textJustify,
    'promptAddToShelf': promptAddToShelf,
  };

  /// 整数值输出成 int（`20` 而不是 `20.0`），与 UI fixture 的写法一致。
  static num _wire(double value) =>
      value == value.roundToDouble() ? value.toInt() : value;
}

/// 解析数值并钳制到 `[min, max]`。
///
/// `double.tryParse` 会接受 `NaN` 与 `Infinity`，直接 clamp 会得到 NaN 或
/// 无穷大，所以必须先过 `isFinite`。
double _number(
  String? raw, {
  required double fallback,
  required double min,
  required double max,
}) {
  if (raw == null) return fallback;
  final parsed = double.tryParse(raw.trim());
  if (parsed == null || !parsed.isFinite) return fallback;
  return parsed.clamp(min, max).toDouble();
}

/// 解析开关。UI 的 Values 可能是 `true`/`1`/`on`，都当开。
bool _flag(String? raw, bool fallback) {
  if (raw == null) return fallback;
  switch (raw.trim().toLowerCase()) {
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
  return fallback;
}

/// 枚举值必须原样命中，否则退默认。
String _enum(String? raw, Set<String> allowed, String fallback) {
  final text = raw?.trim() ?? '';
  return allowed.contains(text) ? text : fallback;
}
