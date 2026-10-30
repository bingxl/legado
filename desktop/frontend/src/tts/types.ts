/**
 * 朗读功能的公共类型。
 *
 * 设计要点：**播放器只认 `Segment`**，不关心它是从 HTML DOM 切出来的（书源/EPUB/TXT），
 * 还是从 pdf.js 的文本层重建出来的（PDF）。两条路径产出同一个抽象，
 * 下游的播放、高亮、进度回写因此只有一套实现。
 */

/** PDF 页内矩形（pdf 坐标系，原点在页面左下；仅为对齐 pdf.js 的约定）。 */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Segment {
  /** 已做朗读前净化的文本（可直接送给 TTS 引擎）。 */
  text: string;
  /** 章序号；PDF 恒为 0，页码另存于 `page`。 */
  chapter: number;
  /** 仅 PDF：0-based 页码。 */
  page?: number;
  /** 仅 PDF：每行一个矩形，用于叠层高亮与点读命中。 */
  rects?: Rect[];
  /** 文本超长被二次切句过：只影响合成粒度，不影响高亮粒度。 */
  long: boolean;
  /** 是否是章节标题段（由阅读器额外前置）。 */
  title?: boolean;
}

/**
 * 文本类段落：额外带上来源元素，用于高亮（加 class）与「点段落从此处读」。
 *
 * 注意：同一元素可能对应多个段落（超长段切句、`<br>` 分行），
 * 此时它们共享同一个 `el`，高亮粒度仍是该元素。
 */
export interface SegmentEl extends Segment {
  el: Element;
}

/** 发音模型。系统音色与 HTTP 引擎的模型走同一抽象。 */
export interface Voice {
  /** 传给引擎的值：系统音色的 voiceURI / `zh-CN-XiaoxiaoNeural` / `zf_xiaobei`。 */
  id: string;
  /** 展示名。 */
  name: string;
  /** BCP-47 语言标记，如 `zh-CN`。 */
  lang?: string;
  /** 所属引擎：`system` 或 `http:<id>`。 */
  engineId: string;
  /** 是否本机合成（系统引擎用；远程音色首句有网络延迟）。 */
  local?: boolean;
}

export type TtsStatus = "idle" | "preparing" | "playing" | "paused" | "error";
