import { describe, expect, it } from "vitest";

import { domSegment } from "./domSegment";
import { segmentHTML } from "./offlineSegment";

describe("segmentHTML（离开阅读器后的离线切段）", () => {
  it("与在线切段结果逐项一致——否则念的和高亮的会错位", () => {
    const html =
      '<div class="txt-content"><p>第一段。</p><p>第二段。<br>第三行。</p></div>';
    const live = document.createElement("div");
    live.innerHTML = html;
    document.body.appendChild(live);

    const online = domSegment(live, { chapter: 2 }).map((s) => s.text);
    const offline = segmentHTML(html, { chapter: 2 }).map((s) => s.text);
    expect(offline).toEqual(online);

    live.remove();
  });

  it("标题前置，且空 HTML 返回空数组", () => {
    const segs = segmentHTML("<p>正文。</p>", { title: "第一章" });
    expect(segs.map((s) => s.text)).toEqual(["第一章", "正文。"]);
    expect(segs[0].title).toBe(true);
    expect(segmentHTML("")).toEqual([]);
  });

  it("噪音行照样被过滤（离线路径不能绕过净化）", () => {
    expect(segmentHTML("<p>请收藏本站最新网址</p>")).toEqual([]);
  });
});
