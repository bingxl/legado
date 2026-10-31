/**
 * 「返回上一页」的统一实现。
 *
 * 为什么不用 `window.history.length > 1` 判断：它不代表站内真的有可回退的
 * 历史——新窗口打开、外链跳入、安卓 WebView 的初始加载都会让它虚高。
 * 直接 `router.back()` 会落到错误页面，比如一路切着 tab 进阅读器后点返回，
 * 退回的是上一个 tab 而不是书籍详情页。
 *
 * 这里改用 vue-router 自己记录的站内 back 入口（`history.state.back`）：
 * 存在且通过匹配检查才真的 back()，否则 replace 到兜底页。
 *
 * - `mustMatch`：back 入口必须以它开头（阅读器只认详情页）。
 * - `exclude`：back 入口以它开头时不算数（详情页排除阅读器，
 *   否则「阅读器→返回→详情→返回」会又退回阅读器）。
 */
export function smartBack(
  router: import("vue-router").Router,
  fallback: string,
  opts: { mustMatch?: string; exclude?: string } = {},
): void {
  const back = router.options.history.state.back;
  const ok =
    typeof back === "string" &&
    (!opts.mustMatch || back.startsWith(opts.mustMatch)) &&
    (!opts.exclude || !back.startsWith(opts.exclude));
  if (ok) {
    router.back();
  } else {
    void router.replace(fallback);
  }
}
