/**
 * HTML → Segment[]（文本类：书源 / EPUB / TXT）。
 *
 * 两条硬约束，改代码前务必守住：
 *
 * 1. **不依赖布局**。不能用 `innerText` / `getComputedStyle`——它们要排版才有值，
 *    而 store 需要在「已挂载的活 DOM」和「离线 document」上得到逐项一致的结果
 *    （同一 HTML + 同一算法 ⇒ 同一段落数组，否则朗读下标与高亮会对不上）。
 * 2. **元素引用要能当高亮锚点**。每个段落带一个 `el`；同一元素可以对应多个段落
 *    （超长切句、`<br>` 分行），此时它们共享 `el`，高亮粒度仍是该元素。
 *
 * 对 `<p>` 这类天然段落的容器不做任何 DOM 改动；只有当同一个块里有 `<br>` 分隔出的
 * 多行文本时，才把每行包进 `<span class="tts-seg">`，好让高亮精确到行而不是整块。
 */

import {
  MAX_SEGMENT_CHARS,
  normalizeSpeechText,
  purifyForSpeech,
  splitLongText,
} from "./text";
import type { SegmentEl } from "./types";

/** 高亮锚点元素的类名（也用于识别「已经包过」的行，避免重复包裹）。 */
export const TTS_SEG_CLASS = "tts-seg";

const BLOCK_TAGS = new Set([
  "ADDRESS",
  "ARTICLE",
  "ASIDE",
  "BLOCKQUOTE",
  "DD",
  "DIV",
  "DL",
  "DT",
  "FIELDSET",
  "FIGCAPTION",
  "FIGURE",
  "FOOTER",
  "FORM",
  "H1",
  "H2",
  "H3",
  "H4",
  "H5",
  "H6",
  "HEADER",
  "LI",
  "MAIN",
  "NAV",
  "OL",
  "P",
  "PRE",
  "SECTION",
  "TABLE",
  "TBODY",
  "TD",
  "TFOOT",
  "TH",
  "THEAD",
  "TR",
  "UL",
]);

/** 不产出文本、也不该进段的元素。 */
const SKIP_TAGS = new Set([
  "AUDIO",
  "BASE",
  "BUTTON",
  "CANVAS",
  "HEAD",
  "HR",
  "IFRAME",
  "IMG",
  "INPUT",
  "LINK",
  "META",
  "NOSCRIPT",
  "SCRIPT",
  "SELECT",
  "STYLE",
  "SVG",
  "TEMPLATE",
  "TEXTAREA",
  "TITLE",
  "VIDEO",
]);

export interface DomSegmentOptions {
  /** 章序号，写进每个段落。 */
  chapter?: number;
  /** 单段字符上限。 */
  maxLen?: number;
  /** 章节标题元素：给了就先输出一段标题（高亮也用同一个元素）。 */
  title?: Element | null;
}

/**
 * 把已渲染的正文容器切成朗读段落。
 *
 * @param root 正文容器（阅读器里的 `.content`）
 */
export function domSegment(
  root: Element,
  opts: DomSegmentOptions = {},
): SegmentEl[] {
  const { chapter = 0, maxLen = MAX_SEGMENT_CHARS, title = null } = opts;
  const out: SegmentEl[] = [];
  if (title) {
    push(out, title.textContent ?? "", title, chapter, maxLen, true);
  }
  walk(root, out, chapter, maxLen);
  return out;
}

function isText(node: Node): boolean {
  return node.nodeType === 3;
}

function isElement(node: Node): node is Element {
  return node.nodeType === 1;
}

/** 收集一段节点列表的纯文本（按文档顺序，跳过不可朗读元素）。 */
function textOfNodes(nodes: Node[]): string {
  let s = "";
  for (const n of nodes) {
    if (isText(n)) {
      s += n.nodeValue ?? "";
    } else if (isElement(n) && !SKIP_TAGS.has(n.tagName)) {
      s += n.textContent ?? "";
    }
  }
  return s;
}

/** 一组节点若本身就是上一次包出来的行 span，直接复用它做锚点。 */
function existingSegEl(group: Node[]): Element | null {
  if (group.length !== 1) return null;
  const n = group[0];
  if (!isElement(n)) return null;
  return n.classList.contains(TTS_SEG_CLASS) ? n : null;
}

/** 把一组节点包进 `<span class="tts-seg">`，返回新元素。 */
function wrapNodes(nodes: Node[]): Element | null {
  const parent = nodes[0]?.parentNode;
  if (!parent) return null;
  const doc = nodes[0].ownerDocument ?? document;
  const span = doc.createElement("span");
  span.className = TTS_SEG_CLASS;
  parent.insertBefore(span, nodes[0]);
  for (const n of nodes) span.appendChild(n);
  return span;
}

/** 按 `<br>` 把节点序列切成若干行。 */
function splitByBr(nodes: Node[]): Node[][] {
  const groups: Node[][] = [];
  let cur: Node[] = [];
  for (const n of nodes) {
    if (isElement(n) && n.tagName === "BR") {
      groups.push(cur);
      cur = [];
      continue;
    }
    cur.push(n);
  }
  groups.push(cur);
  return groups;
}

/** 逐层下降；块级元素递归，行内/裸文本攒成一批后一起处理。 */
function walk(
  container: Element,
  out: SegmentEl[],
  chapter: number,
  maxLen: number,
) {
  let loose: Node[] = [];

  const flush = () => {
    if (!loose.length) return;
    const nodes = loose;
    loose = [];
    emitRuns(container, nodes, out, chapter, maxLen);
  };

  // childNodes 可能被 wrapNodes 改写，先快照一份再遍历。
  for (const node of Array.from(container.childNodes)) {
    if (isText(node)) {
      loose.push(node);
      continue;
    }
    if (!isElement(node)) continue; // 注释等

    const el = node;
    if (el.tagName === "BR") {
      loose.push(el);
      continue;
    }
    if (SKIP_TAGS.has(el.tagName)) continue;
    if (el.classList.contains(TTS_SEG_CLASS)) {
      loose.push(el);
      continue;
    }
    if (BLOCK_TAGS.has(el.tagName)) {
      flush();
      walk(el, out, chapter, maxLen);
      continue;
    }
    loose.push(el);
  }
  flush();
}

/** 处理一批行内节点：单行直接用容器当锚点，多行才包裹成 span。 */
function emitRuns(
  container: Element,
  nodes: Node[],
  out: SegmentEl[],
  chapter: number,
  maxLen: number,
) {
  const groups = splitByBr(nodes).filter(
    (g) => textOfNodes(g).trim().length > 0,
  );
  if (!groups.length) return;

  if (groups.length === 1) {
    const el = existingSegEl(groups[0]) ?? container;
    const raw = el === container ? textOfNodes(groups[0]) : (el.textContent ?? "");
    push(out, raw, el, chapter, maxLen);
    return;
  }

  // 一个块里有多个 `<br>` 行：逐行包裹，高亮才能落到行上。
  for (const g of groups) {
    const existing = existingSegEl(g);
    if (existing) {
      push(out, existing.textContent ?? "", existing, chapter, maxLen);
      continue;
    }
    const span = wrapNodes(g);
    if (span) push(out, span.textContent ?? "", span, chapter, maxLen);
    else push(out, textOfNodes(g), container, chapter, maxLen);
  }
}

/** 净化 + 超长切句后写入结果。空文本（噪音行）直接丢弃。 */
function push(
  out: SegmentEl[],
  raw: string,
  el: Element,
  chapter: number,
  maxLen: number,
  isTitle = false,
) {
  const text = isTitle ? normalizeSpeechText(raw) : purifyForSpeech(raw);
  if (!text) return;
  const pieces = splitLongText(text, maxLen);
  for (const piece of pieces) {
    const seg: SegmentEl = {
      text: piece,
      chapter,
      long: pieces.length > 1,
      el,
    };
    if (isTitle) seg.title = true;
    out.push(seg);
  }
}
