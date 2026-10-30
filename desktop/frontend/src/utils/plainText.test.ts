import { describe, expect, it } from "vitest";

import { wrapPlainTextAsParagraphs } from "./plainText";

describe("wrapPlainTextAsParagraphs", () => {
  it("无标签的纯文本按行变成段落，并去掉自带缩进", () => {
    const out = wrapPlainTextAsParagraphs(
      "　　　　第一行正文。\n　　第二行正文。\n\n第三行正文。",
    );
    expect(out).toBe("<p>第一行正文。</p><p>第二行正文。</p><p>第三行正文。</p>");
  });

  it("有标签时原样返回（EPUB / 漫画 / 正常书源不受影响）", () => {
    const html = "<div><p>已经分了段。</p></div>";
    expect(wrapPlainTextAsParagraphs(html)).toBe(html);
    expect(wrapPlainTextAsParagraphs("<img src='a.png'>")).toBe("<img src='a.png'>");
    expect(wrapPlainTextAsParagraphs("<br>")).toBe("<br>");
  });

  it("正文里的尖括号会被转义，不会被当成标签", () => {
    expect(wrapPlainTextAsParagraphs("a < b 且 c > d")).toBe(
      "<p>a &lt; b 且 c &gt; d</p>",
    );
  });

  it("空输入返回空串", () => {
    expect(wrapPlainTextAsParagraphs("")).toBe("");
    expect(wrapPlainTextAsParagraphs("\n\n  \n")).toBe("");
  });
});
