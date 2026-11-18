import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'pagination.dart';

/// 翻页方式。枚举下标刻意对齐原版 `PageAnim` 的常量值
/// （0 cover / 1 slide / 2 simulation / 3 scroll / 4 none），
/// 以后把阅读配置放进 core 时可以直接按整数互转。
enum PageTurnMode {
  cover('覆盖'),
  slide('滑动'),
  simulation('仿真'),
  scroll('滚动'),
  none('无动画');

  const PageTurnMode(this.label);

  final String label;

  int get code => index;
}

/// 阅读背景预设。原版支持自定义图片/颜色，这里先给固定预设，
/// 文字颜色跟随背景亮度，避免夜间模式下出现黑底黑字。
@immutable
class ReaderBackground {
  const ReaderBackground({
    required this.name,
    required this.color,
    required this.textColor,
    this.dark = false,
  });

  final String name;
  final Color color;
  final Color textColor;
  final bool dark;

  static const paper = ReaderBackground(
    name: '纸黄',
    color: AppTheme.readerPaperColor,
    textColor: Color(0xFF3E3D3B),
  );
  static const white = ReaderBackground(
    name: '米白',
    color: Color(0xFFFFFFFF),
    textColor: Color(0xFF303030),
  );
  static const green = ReaderBackground(
    name: '浅绿',
    color: Color(0xFFCCE8CF),
    textColor: Color(0xFF2F3A31),
  );
  static const gray = ReaderBackground(
    name: '浅灰',
    color: Color(0xFFE3E3E3),
    textColor: Color(0xFF373737),
  );
  static const night = ReaderBackground(
    name: '夜间',
    color: AppTheme.readerNightColor,
    textColor: Color(0xFFADADAD),
    dark: true,
  );

  static const presets = <ReaderBackground>[paper, white, green, gray, night];
}

/// 阅读排版参数。
///
/// 只放「影响分页结果」的字段：分页、渲染、进度换算都从这里取，
/// 避免 UI 各处硬编码字号/行距导致分页与显示不一致。
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
  });

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

  /// 页脚（页码）预留高度：分页时扣掉，正文就不会压到页码上。
  static const double footerHeight = 18;

  ReaderBackground get background =>
      ReaderBackground.presets[backgroundIndex.clamp(0, ReaderBackground.presets.length - 1)];

  /// 渲染用文本样式。分页测量必须用同一份 style，否则行高会对不上。
  TextStyle textStyle(Color color) => TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        color: color,
      );

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
      );

  ReaderStyle copyWith({
    double? fontSize,
    double? lineHeight,
    double? paragraphSpacing,
    String? indent,
    EdgeInsets? pagePadding,
    int? backgroundIndex,
    PageTurnMode? pageTurn,
  }) {
    return ReaderStyle(
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
      indent: indent ?? this.indent,
      pagePadding: pagePadding ?? this.pagePadding,
      backgroundIndex: backgroundIndex ?? this.backgroundIndex,
      pageTurn: pageTurn ?? this.pageTurn,
    );
  }
}

/// 会话级样式缓存。
///
/// 没有接 core 的阅读配置前，至少保证「退出阅读器再进来」字号/背景不丢。
/// 真正的持久化应该由 `Reader.*` 配置方法提供，UI 不本地落盘（避免双份真相）。
class ReaderStyleStore {
  ReaderStyleStore._();

  static ReaderStyle style = const ReaderStyle();

  static void save(ReaderStyle next) => style = next;
}
