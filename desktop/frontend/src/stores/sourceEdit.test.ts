import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * 书源编辑草稿 store 的单测。
 *
 * 重点是「撤销粒度」这条不变量：输入框先清空再输入会被拆成两次 setField，
 * 如果每次都压一步历史，一次撤销只会回到空值，用户会以为撤销坏了。
 * 所以同一字段的连续改动必须合并成一步。
 */
const h = vi.hoisted(() => ({
  get: vi.fn(),
  save: vi.fn(),
}));

vi.mock("@/api/source", () => ({
  sourceApi: {
    get: (...a: unknown[]) => h.get(...a),
    save: (...a: unknown[]) => h.save(...a),
  },
}));

import { useSourceEditStore } from "./sourceEdit";

/** 每步改动之间的停顿：大于 500ms 的合并窗口后才落一步历史。 */
const SETTLE = 600;

function srcView(raw: Record<string, unknown>) {
  return {
    id: 7,
    name: String(raw.bookSourceName ?? ""),
    url: String(raw.bookSourceUrl ?? ""),
    group: "",
    comment: "",
    enabled: true,
    order: 0,
    lastUpdateAt: 0,
    raw: JSON.stringify(raw),
  };
}

const BASE_RAW = {
  bookSourceName: "原名",
  bookSourceUrl: "https://example.com",
  bookSourceComment: "",
};

function openLoaded() {
  const store = useSourceEditStore();
  store.reset(srcView(BASE_RAW) as never);
  return store;
}

beforeEach(() => {
  setActivePinia(createPinia());
  vi.useFakeTimers();
  h.get.mockReset();
  h.save.mockReset();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("sourceEdit 草稿", () => {
  it("刚打开时不算有未保存修改", () => {
    const store = openLoaded();
    expect(store.dirty).toBe(false);
    expect(store.canUndo).toBe(false);
  });

  it("改字段后置脏，撤销回到原值并清脏", () => {
    const store = openLoaded();
    store.setField(["bookSourceName"], "新名");
    vi.advanceTimersByTime(SETTLE);
    expect(store.dirty).toBe(true);

    store.undo();
    expect(store.getField(["bookSourceName"])).toBe("原名");
    expect(store.dirty).toBe(false);
  });

  it("同一字段「先清空再输入」只算一步撤销", () => {
    const store = openLoaded();
    // 输入框清空 → 500ms 后才敲字，真实用户慢慢打字就是这个节奏
    store.setField(["bookSourceName"], "");
    vi.advanceTimersByTime(SETTLE);
    store.setField(["bookSourceName"], "新名");
    vi.advanceTimersByTime(SETTLE);

    store.undo();
    expect(store.getField(["bookSourceName"])).toBe("原名");
    expect(store.canUndo).toBe(false);
  });

  it("改了不同字段则是两步撤销", () => {
    const store = openLoaded();
    store.setField(["bookSourceName"], "新名");
    vi.advanceTimersByTime(SETTLE);
    store.setField(["bookSourceComment"], "备注");
    vi.advanceTimersByTime(SETTLE);

    store.undo();
    expect(store.getField(["bookSourceComment"])).toBe("");
    expect(store.getField(["bookSourceName"])).toBe("新名");
    store.undo();
    expect(store.getField(["bookSourceName"])).toBe("原名");
  });

  it("撤销之后继续编辑不会被合并进旧的那一步", () => {
    const store = openLoaded();
    store.setField(["bookSourceName"], "第一次");
    vi.advanceTimersByTime(SETTLE);
    store.undo();
    store.setField(["bookSourceName"], "第二次");
    vi.advanceTimersByTime(SETTLE);

    store.undo();
    expect(store.getField(["bookSourceName"])).toBe("原名");
    store.redo();
    expect(store.getField(["bookSourceName"])).toBe("第二次");
  });

  it("「重新载入」后再保存：JSON 语法错误已被丢弃", () => {
    const store = openLoaded();
    expect(store.applyRawText('{"bookSourceUrl": ')).toBe(false);
    expect(store.rawError).not.toBe("");

    store.discardRawError();
    expect(store.rawError).toBe("");
    // 草稿本身没被那段非法文本污染
    expect(store.getField(["bookSourceName"])).toBe("原名");
  });
});
