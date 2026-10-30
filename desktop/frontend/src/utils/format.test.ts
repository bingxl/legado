import { describe, expect, it } from "vitest";

import { formatBytes, formatDateTime } from "./format";

describe("formatBytes", () => {
  it("按常见的容量单位换算", () => {
    expect(formatBytes(0)).toBe("0 B");
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(1024)).toBe("1 KB");
    expect(formatBytes(1536)).toBe("1.5 KB");
    expect(formatBytes(1024 * 1024)).toBe("1 MB");
    expect(formatBytes(1024 * 1024 * 200)).toBe("200 MB");
    expect(formatBytes(1024 * 1024 * 1024 * 2.5)).toBe("2.5 GB");
  });

  it("对负数与非法值兜底为 0 B", () => {
    expect(formatBytes(-1)).toBe("0 B");
    expect(formatBytes(Number.NaN)).toBe("0 B");
  });
});

describe("formatDateTime", () => {
  it("格式化为 MM-DD HH:mm", () => {
    const iso = new Date(2026, 0, 8, 9, 5).toISOString();
    expect(formatDateTime(iso)).toBe("01-08 09:05");
  });

  it("空值与非法值返回空串", () => {
    expect(formatDateTime(null)).toBe("");
    expect(formatDateTime(undefined)).toBe("");
    expect(formatDateTime("not-a-date")).toBe("");
  });
});
