import { afterEach, describe, expect, it } from "vitest";

import { TTS_SEG_CLASS, domSegment } from "./domSegment";

let mounted: HTMLElement[] = [];

/** 挂到 body 的容器（模拟阅读器里的活 DOM）。 */
function live(html: string): HTMLElement {
  const wrap = document.createElement("div");
  wrap.innerHTML = html;
  document.body.appendChild(wrap);
  mounted.push(wrap);
  return wrap;
}

/** 离线 document 里的容器（模拟「不在渲染树上」的那条路径）。 */
function offline(html: string): HTMLElement {
  const doc = document.implementation.createHTMLDocument("offline");
  const wrap = doc.createElement("div");
  wrap.innerHTML = html;
  return wrap;
}

function texts(root: Element): string[] {
  return domSegment(root).map((s) => s.text);
}

afterEach(() => {
  for (const el of mounted) el.remove();
  mounted = [];
});

describe("domSegment 切段", () => {
  it("多个 <p> 各成一段", () => {
    const root = live("<p>第一段。</p><p>第二段。</p>");
    expect(texts(root)).toEqual(["第一段。", "第二段。"]);
  });

  it("嵌套块级元素逐层下降", () => {
    const root = live(
      '<div class="txt-content"><section><p>甲。</p><p>乙。</p></section></div>',
    );
    expect(texts(root)).toEqual(["甲。", "乙。"]);
  });

  it("同一个 <p> 里的 <br> 拆成多段，并各自可高亮", () => {
    const root = live("<p>甲。<br>乙。<br><br>丙。</p>");
    const segs = domSegment(root);
    expect(segs.map((s) => s.text)).toEqual(["甲。", "乙。", "丙。"]);
    // 拆出来的行各自包了 span，高亮才能落到行而不是整块
    expect(new Set(segs.map((s) => s.el)).size).toBe(3);
    for (const s of segs) {
      expect(s.el.classList.contains(TTS_SEG_CLASS)).toBe(true);
    }
  });

  it("裸文本 + <br> 也能成段", () => {
    const root = live("<br><br>裸文本<br>更多");
    expect(texts(root)).toEqual(["裸文本", "更多"]);
  });

  it("跳过 script/style/img 与噪音行", () => {
    const root = live(
      "<p>正文。</p><script>var a=1</script><style>.a{}</style>" +
        "<p>请收藏本站最新网址</p><p><img src='x.png'></p>",
    );
    expect(texts(root)).toEqual(["正文。"]);
  });

  it("标题单独前置，且不参与正文去重", () => {
    const root = live("<p>正文。</p>");
    const h1 = document.createElement("h1");
    h1.textContent = "第 3 章 夜行";
    const segs = domSegment(root, { title: h1 });
    // 「章 夜行」中间那个空格会被 CJK 粘连修复吃掉——中文朗读听不出差别，
    // 播放条上显示的标题仍取目录里的原文。
    expect(segs.map((s) => s.text)).toEqual(["第 3 章夜行", "正文。"]);
    expect(segs[0].title).toBe(true);
    expect(segs[0].el).toBe(h1);
  });

  it("超长段落被二次切句，但共享同一个元素", () => {
    const long = Array.from({ length: 40 }, () => "这一句用来凑长度。").join("");
    const root = live(`<p>${long}</p>`);
    const segs = domSegment(root, { maxLen: 100 });
    expect(segs.length).toBeGreaterThan(1);
    expect(segs.every((s) => s.text.length <= 100)).toBe(true);
    expect(segs.every((s) => s.long)).toBe(true);
    expect(new Set(segs.map((s) => s.el)).size).toBe(1);
  });

  it("段落记录所属章号", () => {
    const root = live("<p>正文。</p>");
    expect(domSegment(root, { chapter: 7 })[0].chapter).toBe(7);
  });
});

describe("索引不变量", () => {
  const CASES = [
    "<p>甲。</p><p>乙。</p>",
    "<p>甲。<br>乙。</p>",
    "<br>甲<br>乙<br>",
    "<div><p>甲。</p><div><p>乙。<br>丙。</p></div></div>",
    "<p>甲。</p><p>请收藏本站</p><p>乙。</p>",
  ];

  it.each(CASES)("离线解析与挂载后切段结果一致：%s", (html) => {
    expect(texts(offline(html))).toEqual(texts(live(html)));
  });

  it.each(CASES)("重复切段结果稳定（包裹 span 不改变结论）：%s", (html) => {
    const root = live(html);
    const first = texts(root);
    const second = texts(root);
    const third = texts(root);
    expect(second).toEqual(first);
    expect(third).toEqual(first);
  });

  it("高亮锚点仍指向同一批元素（重复切段不重建 span）", () => {
    const root = live("<p>甲。<br>乙。</p>");
    const first = domSegment(root).map((s) => s.el);
    const second = domSegment(root).map((s) => s.el);
    expect(second).toEqual(first);
  });
});
