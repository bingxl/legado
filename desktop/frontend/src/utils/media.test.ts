import { describe, expect, it } from "vitest";

import { comicImageURL, coverURL } from "./media";
import { extOf, pathArg, rawFileURL, rawImageURL } from "./assetUrl";

/** 按后端 asset_url.go 的规则还原路径段（顺带验证前后端编码互补）。 */
function decodeWrap(url: string): { payload: string; ext: string } {
  const rest = url.replace(/^\/(raw|img)\//, "");
  const i = rest.lastIndexOf(".");
  const seg = i > 0 ? rest.slice(0, i) : rest;
  const ext = i > 0 ? rest.slice(i) : "";
  const bin = atob(seg.replace(/-/g, "+").replace(/_/g, "/"));
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return { payload: new TextDecoder().decode(bytes), ext };
}

describe("extOf", () => {
  it("取小写扩展名，遇到查询串先摘掉", () => {
    expect(extOf("C:/a/书源.JSON")).toBe(".json");
    expect(extOf("/x/y.Book.PDF")).toBe(".pdf");
    expect(extOf("https://cdn/x/1.webp?token=abc")).toBe(".webp");
  });

  it("不像扩展名时留空", () => {
    expect(extOf("/x/没有后缀")).toBe("");
    expect(extOf("https://cdn/x/1.webp/")).toBe("");
    expect(extOf("https://cdn/x/a.b/verylongextension")).toBe("");
  });
});

describe("rawFileURL", () => {
  // 安卓端只把路径交给后端，查询串会丢 —— 一旦出现 "?" 就又回到 Failed to fetch。
  it("不用查询串，路径段可还原原绝对路径", () => {
    const abs = "C:\\Users\\bingx\\下载\\书源.json";
    const url = rawFileURL(abs);
    expect(url).not.toContain("?");
    expect(url.startsWith("/raw/")).toBe(true);
    const { payload, ext } = decodeWrap(url);
    expect(payload).toBe(abs);
    expect(ext).toBe(".json");
  });

  it("没有扩展名时不追加空点", () => {
    const url = rawFileURL("/data/user/0/cn.bingxl.legado/cache/noext");
    expect(url).not.toContain("?");
    expect(decodeWrap(url).payload).toBe("/data/user/0/cn.bingxl.legado/cache/noext");
  });
});

describe("rawImageURL", () => {
  it("图片地址与书源地址一起编进路径段", () => {
    const url = rawImageURL("https://cdn.example.com/a/1.jpg", "https://manwame.com");
    expect(url).not.toContain("?");
    const { payload, ext } = decodeWrap(url);
    expect(payload).toBe("https://cdn.example.com/a/1.jpg\nhttps://manwame.com");
    expect(ext).toBe(".jpg");
  });
});

describe("comicImageURL", () => {
  it("网络图片走 /img/ 代理（带书源地址作 Referer）", () => {
    expect(comicImageURL("https://cdn/x/1.png", "https://src.site")).toBe(
      rawImageURL("https://cdn/x/1.png", "https://src.site"),
    );
  });

  it("本地图片沿用 /local/ 与 /raw/ 规则", () => {
    expect(comicImageURL("/local/cache/chapter/1/001.jpg")).toBe("/local/cache/chapter/1/001.jpg");
    expect(comicImageURL("/tmp/c.jpg")).toBe(rawFileURL("/tmp/c.jpg"));
  });

  it("空地址返回空串", () => {
    expect(comicImageURL("")).toBe("");
  });
});

describe("coverURL", () => {
  it("本地封面转 /raw/，网络封面原样返回", () => {
    expect(coverURL("https://img/x.jpg")).toBe("https://img/x.jpg");
    expect(coverURL("/local/covers/1.jpg")).toBe("/local/covers/1.jpg");
    expect(coverURL("/tmp/封面.jpg")).toBe(rawFileURL("/tmp/封面.jpg"));
    expect(coverURL("")).toBe("");
  });
});

describe("pathArg", () => {
  it("输出 base64url（不含 + / =）", () => {
    const out = pathArg("a?b&c/中文?>>>");
    expect(out).toMatch(/^[A-Za-z0-9_-]+$/);
  });
});
