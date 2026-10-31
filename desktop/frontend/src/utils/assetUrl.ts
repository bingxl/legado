/**
 * 本地资源与图片代理的 URL 构造。
 *
 * 单独成文件（不依赖 Wails 绑定），这样单测可以直接跑，不必拉起运行时。
 *
 * 组装规则：参数编进**路径段**（base64url），不用查询串。
 * 安卓宿主的资源拦截器（WebViewAssetLoader.PathHandler）只把路径交给 Go，
 * 查询串在到达后端前就丢了，`/raw/?p=...` 在安卓端会变成 p 为空的请求，
 * 最终表现为前端 fetch 抛 "Failed to fetch"（导入书源失败就是这个）。
 *
 * 参数后追加文件扩展名的原因：安卓侧按路径扩展名决定 Content-Type，
 * PDF 拿不到 application/pdf 就没法内嵌预览。
 */

/** 把任意文本编成 base64url（UTF-8，无 padding），可安全放进路径段。 */
export function pathArg(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/**
 * 取扩展名（含点，小写）。不像扩展名时留空，交给内容嗅探
 * （图片地址常带 `?token=` 之类的尾巴，先摘掉再判断）。
 */
export function extOf(value: string): string {
  const m = /\.([A-Za-z0-9]{1,8})$/.exec(value.split(/[?#]/)[0]);
  return m ? "." + m[1].toLowerCase() : "";
}

/** 本地文件的 WebView 可加载地址：`/raw/<base64url(绝对路径)>[.ext]`。 */
export function rawFileURL(absPath: string): string {
  return "/raw/" + pathArg(absPath) + extOf(absPath);
}

/**
 * 网络图片代理地址：`/img/<base64url(图片地址 + "\n" + 书源地址)>[.ext]`。
 *
 * 图床普遍校验 Referer，必须由后端带上书源域名去取。
 */
export function rawImageURL(url: string, origin = ""): string {
  return "/img/" + pathArg(url + "\n" + origin) + extOf(url);
}
