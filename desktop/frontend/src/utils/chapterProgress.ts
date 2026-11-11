/**
 * 本章进度换算（阅读器底部进度条）。
 *
 * 单独抽出来是因为两边必须用同一个公式：进度条显示的位置、正文滚动到的位置、
 * 拖动时百分比反算的滚动量。三处各写一份就会出现「拖到 50%，松手跳到 47%」。
 * 纯函数不碰 DOM，方便单测。
 */

/** 把百分比夹到 0~100；NaN / Infinity 一律当 0。 */
export function clampPercent(p: number): number {
  if (!Number.isFinite(p)) return 0;
  return Math.min(100, Math.max(0, p));
}

/**
 * 滚动位置 → 百分比（四舍五入到整数，进度条只显示整数）。
 *
 * 内容不足一屏（max <= 0）时返回 100：整章内容都在屏幕上，就是「已读到头」。
 * 调用方可以据此同时把进度条置为不可拖动（没有可滚的范围）。
 */
export function percentFromScroll(
  scrollTop: number,
  scrollHeight: number,
  clientHeight: number,
): number {
  const max = scrollHeight - clientHeight;
  if (!(max > 0)) return 100;
  return clampPercent(Math.round((scrollTop / max) * 100));
}

/** 百分比 → 滚动位置（percentFromScroll 的逆运算）。内容不足一屏时恒为 0。 */
export function scrollTopForPercent(
  percent: number,
  scrollHeight: number,
  clientHeight: number,
): number {
  const max = scrollHeight - clientHeight;
  if (!(max > 0)) return 0;
  return (clampPercent(percent) / 100) * max;
}

/** 指针横坐标 → 百分比（进度条轨道的命中换算）。 */
export function percentFromX(clientX: number, left: number, width: number): number {
  if (!(width > 0)) return 0;
  return clampPercent(((clientX - left) / width) * 100);
}
