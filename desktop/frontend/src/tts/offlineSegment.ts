/**
 * 离线切段：拿后端返回的 HTML 直接解析，不依赖阅读器里的活 DOM。
 *
 * 用途只有一个——**离开阅读器后还要继续朗读**。此时组件已卸载，
 * 拿不到 `.content` 元素，但 `ReaderAPI.GetContent` 仍然可用，
 * 于是把这批 HTML 塞进一个游离 document 里切段。
 *
 * 结果必须与在线切段逐项一致，否则「念的」和「高亮的」会错位；
 * 这条不变量由 `domSegment.test.ts` 守着（同一 HTML 离线/在线结果相等）。
 */

import { wrapPlainTextAsParagraphs } from "@/utils/plainText";

import { domSegment } from "./domSegment";
import type { SegmentEl } from "./types";

export interface OfflineSegmentOptions {
  chapter?: number;
  /** 章节标题；给了就作为第一段（与阅读器里的行为保持一致）。 */
  title?: string;
}

export function segmentHTML(
  html: string,
  opts: OfflineSegmentOptions = {},
): SegmentEl[] {
  if (!html) return [];
  const doc = document.implementation.createHTMLDocument("tts");
  const root = doc.createElement("div");
  // 与阅读器渲染走同一个转换：纯文本书源要按行补段落，否则切出来是一整块。
  root.innerHTML = wrapPlainTextAsParagraphs(html);

  let titleEl: Element | null = null;
  if (opts.title) {
    titleEl = doc.createElement("h1");
    titleEl.textContent = opts.title;
  }
  return domSegment(root, { chapter: opts.chapter ?? 0, title: titleEl });
}
