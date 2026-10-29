/**
 * 媒体地址处理。
 *
 * 书籍封面既可能是网络 URL，也可能是本地绝对路径。
 * 后者无法直接塞进 <img src>，需要经后端的 /raw/ 路由转换。
 */
import { rawFileURL } from "@/api/system";

/** 把封面地址转换为 WebView 可加载的 URL。 */
export function coverURL(cover: string): string {
  if (!cover) return "";
  if (/^https?:\/\//i.test(cover)) return cover;
  if (cover.startsWith("/local/") || cover.startsWith("/raw/")) return cover;
  return rawFileURL(cover);
}

/** 是否网络地址。 */
export function isRemote(url: string): boolean {
  return /^https?:\/\//i.test(url);
}

/**
 * 漫画章节图片地址。
 *
 * 网络图片必须走后端 `/img/` 代理：图床普遍校验 Referer，WebView 直接加载
 * 时发出的是应用自身来源，会被判为盗链直接 403。代理会带上书源域名作 Referer。
 * 本地图片（comic 压缩包解压出来的）沿用 /local/ 规则。
 *
 * @param origin 书源地址（book.origin），代理只取它的 scheme://host 作 Referer
 */
export function comicImageURL(url: string, origin = ""): string {
  if (!url) return "";
  if (!isRemote(url)) return coverURL(url);
  return `/img/?u=${encodeURIComponent(url)}&src=${encodeURIComponent(origin)}`;
}
