/// 阅读器进度条的统一口径。
///
/// 原版 `ReadMenu` / `MangaMenu` 的 seekBar 都是 `max = count - 1`：
/// 第一项 0%、最后一项 100%，拖动松手跳到对应项。这里把「项」抽象成
/// 章内分页、章内图片、PDF 分段内的页，三套阅读器共用同一套换算。
///
/// 与落盘进度 [percentForPageIndex]（index / count，末页差一格）不是一回事，
/// 两者不要互相替代。
class ReaderProgress {
  const ReaderProgress({required this.index, required this.count});

  /// 章内当前项索引（0-based）。
  final int index;

  /// 章内总项数。
  final int count;

  /// 进度条位置（0~1），末项恰好是 1。
  double get percent => readPercentForIndex(index, count);

  /// 相邻页码标签，例如 `3/12`。没有项时显示 `--`。
  String get label => count <= 0 ? '--' : '${index + 1}/$count';
}

/// 项索引 → 进度条百分比（首页 0、末项 1）。
double readPercentForIndex(int index, int count) {
  if (count <= 0) return 0;
  if (count == 1) return 1;
  return (index.clamp(0, count - 1) / (count - 1)).clamp(0.0, 1.0);
}

/// 进度条百分比 → 项索引（末项对应 100%）。
int indexForReadPercent(double percent, int count) {
  if (count <= 0) return 0;
  if (count == 1) return 0;
  return (percent.clamp(0.0, 1.0) * (count - 1)).round().clamp(0, count - 1);
}
