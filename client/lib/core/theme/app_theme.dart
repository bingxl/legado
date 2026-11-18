import 'package:flutter/material.dart';

/// 主题基准取自原版 legado（`app/src/main/res/values/colors.xml`）：
/// 浅蓝 accent `#578FCC`、深色主文字、暖白纸张阅读背景。
class AppTheme {
  AppTheme._();

  static const accent = Color(0xFF578FCC);
  static const error = Color(0xFFEB4333);
  static const success = Color(0xFF439B53);
  static const highlight = Color(0xFFD3321B);

  /// 阅读器纸张主题（与阅读设置里的主题项一一对应）。
  static const readerPaperColor = Color(0xFFF6F1E1);
  static const readerNightColor = Color(0xFF1A1A1A);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    ).copyWith(
      error: error,
      surface: const Color(0xFFFFFBFE),
    );
    return _base(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(error: error);
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 1,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      listTileTheme: const ListTileThemeData(
        visualDensity: VisualDensity.compact,
        minVerticalPadding: 10,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.onSurface.withValues(alpha: 0.08),
        thickness: 0.6,
        space: 0.6,
      ),
      // 桌面端用鼠标时不应出现移动端的涟漪放大效果。
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
