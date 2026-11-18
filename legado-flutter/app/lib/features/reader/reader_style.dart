import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'pagination.dart';

/// 翻页方式。枚举下标刻意对齐原版 `PageAnim` 的常量值
/// （0 cover / 1 slide / 2 simulation / 3 scroll / 4 none），
/// 以后把阅读配置放进 core 时可以直接按整数互转。
enum PageTurnMode {
  cover('覆盖', 'cover'),
  slide('滑动', 'slide'),
  simulation('仿真', 'simulation'),
  scroll('滚动', 'scroll'),
  none('无动画', 'none');

  const PageTurnMode(this.label, this.value);

  final String label;

  /// 与 core 的 `reader.pageTurn` 配置值对应。
  final String value;

  int get code => index;

  /// 按配置值找翻页方式；值不认识时退回覆盖（与 core 的默认值一致）。
  static PageTurnMode fromValue(String? value) {
    for (final mode in values) {
      if (mode.value == value) return mode;
    }
    return cover;
  }
}

/// 阅读背景预设。原版支持自定义图片/颜色，这里先给固定预设，
/// 文字颜色跟随背景亮度，避免夜间模式下出现黑底黑字。
@immutable
class ReaderBackground {
  const ReaderBackground({
    required this.name,
    required this.color,
    required this.textColor,
    required this.value,
    this.dark = false,
  });

  final String name;
  final Color color;
  final Color textColor;

  /// 与 core 的 `reader.theme` 配置值对应（见 `core/modules/settings/schema.go`）。
  /// 顺序必须和 [presets] 一致，否则「设置页选夜间、阅读器却是纸黄」。
  final String value;

  final bool dark;

  static const paper = ReaderBackground(
    name: '纸黄',
    value: 'paper',
    color: AppTheme.readerPaperColor,
    textColor: Color(0xFF3E3D3B),
  );
  static const white = ReaderBackground(
    name: '米白',
    value: 'white',
    color: Color(0xFFFFFFFF),
    textColor: Color(0xFF303030),
  );
  static const green = ReaderBackground(
    name: '浅绿',
    value: 'green',
    color: Color(0xFFCCE8CF),
    textColor: Color(0xFF2F3A31),
  );
  static const gray = ReaderBackground(
    name: '浅灰',
    value: 'gray',
    color: Color(0xFFE3E3E3),
    textColor: Color(0xFF373737),
  );
  static const night = ReaderBackground(
    name: '夜间',
    value: 'night',
    color: AppTheme.readerNightColor,
    textColor: Color(0xFFADADAD),
    dark: true,
  );

  static const presets = <ReaderBackground>[paper, white, green, gray, night];

  /// 按配置值找预设；值不认识时退回纸黄（旧版本写下的脏值不该让阅读器白屏）。
  static int indexOfValue(String? value) {
    for (var i = 0; i < presets.length; i++) {
      if (presets[i].value == value) return i;
    }
    return 0;
  }
}

/// 阅读排版参数。
///
/// 只放「影响分页结果」的字段：分页、渲染、进度换算都从这里取，
/// 避免 UI 各处硬编码字号/行距导致分页与显示不一致。
///
/// 真源是 core 的 `Settings.Reader`（见 `features/settings`），本类只承载
/// 「这次渲染要用的那一份」；[fromPrefs] 是配置 → 样式的唯一转换点，
/// 阅读器各处不再各自拼装，否则设置页改了字号、阅读器却没跟上。
@immutable
class ReaderStyle {
  const ReaderStyle({
    this.fontSize = 20,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 10,
    this.indent = '　　',
    this.pagePadding = const EdgeInsets.fromLTRB(20, 12, 20, 8),
    this.backgroundIndex = 0,
    this.pageTurn = PageTurnMode.cover,
    this.showPageNumber = true,
    this.textJustify = true,
  });

  /// 用 core 下发的配置构造样式。
  ///
  /// 参数刻意保持「原始类型 + 字符串配置值」而不是直接吃 settings 模块的
  /// 类型：阅读器不该依赖设置页的数据结构，反过来设置页需要读本模块的
  /// 背景预设（取色），单向依赖才不会成环。
  factory ReaderStyle.fromPrefs({
    required double fontSize,
    required double lineHeight,
    required double paragraphSpacing,
    required bool indentFirstLine,
    required double paddingHorizontal,
    required double paddingVertical,
    required String theme,
    required String pageTurn,
    required bool showPageNumber,
    required bool textJustify,
  }) {
    return ReaderStyle(
      fontSize: fontSize,
      lineHeight: lineHeight,
      paragraphSpacing: paragraphSpacing,
      // 缩进是「参与测量的文本前缀」而不是排版属性，关掉就是空串。
      indent: indentFirstLine ? '　　' : '',
      pagePadding: EdgeInsets.fromLTRB(
        paddingHorizontal,
        paddingVertical,
        paddingHorizontal,
        paddingVertical,
      ),
      backgroundIndex: ReaderBackground.indexOfValue(theme),
      pageTurn: PageTurnMode.fromValue(pageTurn),
      showPageNumber: showPageNumber,
      textJustify: textJustify,
    );
  }

  final double fontSize;

  /// 行高倍数。中文正文 1.8 在桌面/移动端都足够透气（原版默认约 1.6~1.8）。
  final double lineHeight;

  /// 段间距（逻辑像素）。原版用空行分隔段落，这里改为固定间距，版面更稳定。
  final double paragraphSpacing;

  /// 首行缩进，直接作为文本前缀参与测量，避免首行少算两字宽导致折行错位。
  final String indent;

  final EdgeInsets pagePadding;

  final int backgroundIndex;

  final PageTurnMode pageTurn;

  /// 是否在页脚显示页码（章节名始终显示）。
  final bool showPageNumber;

  /// 是否两端对齐。关闭后左对齐，右侧留自然参差。
  final bool textJustify;

  /// 页脚（页码）预留高度：分页时扣掉，正文就不会压到页码上。
  static const double footerHeight = 18;

  ReaderBackground get background =>
      ReaderBackground.presets[backgroundIndex.clamp(
        0,
        ReaderBackground.presets.length - 1,
      )];

  /// 渲染用文本样式。分页测量必须用同一份 style，否则行高会对不上。
  TextStyle textStyle(Color color) =>
      TextStyle(fontSize: fontSize, height: lineHeight, color: color);

  /// 正文对齐方式。分页测量与渲染必须一致（见 [ReaderTypography.justify]）。
  TextAlign get align => textJustify ? TextAlign.justify : TextAlign.start;

  /// 版心尺寸（视口扣除页边距与页脚）。分页与渲染都以它为准。
  Size contentSize(Size viewport) => Size(
    math.max(1, viewport.width - pagePadding.horizontal),
    math.max(1, viewport.height - pagePadding.vertical - footerHeight),
  );

  ReaderTypography get typography => ReaderTypography(
    fontSize: fontSize,
    lineHeight: lineHeight,
    paragraphSpacing: paragraphSpacing,
    indent: indent,
    justify: textJustify,
  );

  ReaderStyle copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    String? indent,
    EdgeInsets? pagePadding,
    int? backgroundIndex,
    PageTurnMode? pageTurn,
    bool? showPageNumber,
    bool? textJustify,
  }) {
    return ReaderStyle(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      indent: indent ?? this.indent,
      pagePadding: pagePadding ?? this.pagePadding,
      backgroundIndex: backgroundIndex ?? this.backgroundIndex,
      pageTurn: pageTurn ?? this.pageTurn,
      showPageNumber: showPageNumber ?? this.showPageNumber,
      textJustify: textJustify ?? this.textJustify,
    );
  }

  /// 把影响「可持久化」的字段转成 core 的配置补丁。
  ///
  /// 阅读器里的字号/背景调整要写回 core，否则退出重进就回到设置页的值。
  /// 只导出与设置项一一对应的字段，段距/缩进这类只在设置页改。
  Map<String, String> toPrefsPatch() => {
    'reader.fontSize': fontSize.toStringAsFixed(0),
    'reader.lineHeight': lineHeight.toString(),
    'reader.theme': background.value,
    'reader.pageTurn': pageTurn.value,
  };
}
