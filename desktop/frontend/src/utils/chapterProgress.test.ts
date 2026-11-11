import { describe, expect, it } from "vitest";

import {
  clampPercent,
  percentFromScroll,
  percentFromX,
  scrollTopForPercent,
} from "./chapterProgress";

describe("clampPercent", () => {
  it("夹在 0~100", () => {
    expect(clampPercent(-1)).toBe(0);
    expect(clampPercent(101)).toBe(100);
    expect(clampPercent(42.6)).toBe(42.6);
  });

  it("非有限数当 0", () => {
    expect(clampPercent(Number.NaN)).toBe(0);
    expect(clampPercent(Number.POSITIVE_INFINITY)).toBe(0);
  });
});

describe("percentFromScroll", () => {
  it("按可滚动范围换算", () => {
    expect(percentFromScroll(0, 2000, 500)).toBe(0);
    expect(percentFromScroll(750, 2000, 500)).toBe(50);
    expect(percentFromScroll(1500, 2000, 500)).toBe(100);
  });

  it("不足一屏算 100（整章可见）", () => {
    expect(percentFromScroll(0, 400, 500)).toBe(100);
    expect(percentFromScroll(0, 500, 500)).toBe(100);
  });
});

describe("scrollTopForPercent", () => {
  it("与 percentFromScroll 互逆", () => {
    for (const p of [0, 1, 33, 50, 99, 100]) {
      const top = scrollTopForPercent(p, 2000, 500);
      expect(percentFromScroll(top, 2000, 500)).toBe(p);
    }
  });

  it("不足一屏恒为 0", () => {
    expect(scrollTopForPercent(80, 400, 500)).toBe(0);
  });
});

describe("percentFromX", () => {
  it("按轨道左边界与宽度换算", () => {
    expect(percentFromX(100, 100, 200)).toBe(0);
    expect(percentFromX(200, 100, 200)).toBe(50);
    expect(percentFromX(300, 100, 200)).toBe(100);
  });

  it("超出轨道时夹住而不是溢出", () => {
    expect(percentFromX(50, 100, 200)).toBe(0);
    expect(percentFromX(400, 100, 200)).toBe(100);
  });

  it("轨道宽度为 0 时返回 0", () => {
    expect(percentFromX(100, 0, 0)).toBe(0);
  });
});
