import 'package:flutter/material.dart';

import '../progress.dart';

/// 三套阅读器共用的底部进度条。
///
/// 拖动期间只更新本地临时值，松手才回调 [onSeek] —— 对齐原版
/// `onStopTrackingTouch` 的行为，避免拖过一串图片反复触发跳转/解码。
/// 传 [themeData] 可覆盖滑块外观（漫画/PDF 是深色面板，文字跟随阅读主题）。
class ReaderProgressSlider extends StatefulWidget {
  const ReaderProgressSlider({
    super.key,
    required this.progress,
    required this.onSeek,
    this.themeData,
    this.enabled = true,
  });

  final ReaderProgress progress;

  /// 松手时回调，参数是 0~1 的进度条百分比。
  final ValueChanged<double> onSeek;

  final SliderThemeData? themeData;

  /// 没有可跳项时禁用（例如文字章没有分页数据的瞬间）。
  final bool enabled;

  @override
  State<ReaderProgressSlider> createState() => _ReaderProgressSliderState();
}

class _ReaderProgressSliderState extends State<ReaderProgressSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    // 没有可跳项时自己禁用，调用方不必额外记得传 enabled=false。
    final canSeek = widget.enabled && widget.progress.count > 0;
    final percent = _dragValue ?? widget.progress.percent;
    final label = widget.progress.count <= 0
        ? '--'
        : '${indexForReadPercent(percent, widget.progress.count) + 1}'
            '/${widget.progress.count}';
    final slider = Slider(
      value: percent.clamp(0.0, 1.0),
      // count <= 1 时 divisions 必须省略，否则 Slider 断言失败。
      divisions: widget.progress.count > 1 ? widget.progress.count - 1 : null,
      label: label,
      onChanged:
          canSeek ? (value) => setState(() => _dragValue = value) : null,
      onChangeEnd: canSeek
          ? (value) {
              setState(() => _dragValue = null);
              widget.onSeek(value);
            }
          : null,
    );
    final theme = widget.themeData;
    return theme == null ? slider : SliderTheme(data: theme, child: slider);
  }
}
