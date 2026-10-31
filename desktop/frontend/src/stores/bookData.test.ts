import { createPinia, setActivePinia } from "pinia";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

/**
 * 书籍数据缓存 store 的单测。
 *
 * 重点：缓存命中 / 进度落盘失效 / 手动刷新连带失效正文 / TTL 过期。
 */
const h = vi.hoisted(() => ({
  getBook: vi.fn(),
  getChapters: vi.fn(),
  getContent: vi.fn(),
}));

vi.mock("@/api/bookshelf", () => ({
  bookshelfApi: { getBook: (...a: unknown[]) => h.getBook(...a) },
}));

vi.mock("@/api/reader", () => ({
  readerApi: {
    getChapters: (...a: unknown[]) => h.getChapters(...a),
    getContent: (...a: unknown[]) => h.getContent(...a),
  },
}));

import { BOOK_DATA_TTL, useBookDataStore } from "./bookData";

beforeEach(() => {
  setActivePinia(createPinia());
  h.getBook.mockReset();
  h.getChapters.mockReset();
  h.getContent.mockReset();
});

afterEach(() => {
  vi.useRealTimers();
});

describe("bookData 缓存", () => {
  it("同一本书的详情与目录只拉一次", async () => {
    h.getBook.mockResolvedValue({ id: 1, name: "书" });
    h.getChapters.mockResolvedValue([{ index: 0, title: "第一章" }]);
    const s = useBookDataStore();

    await s.getBook(1);
    await s.getBook(1);
    await s.getChapters(1);
    await s.getChapters(1);

    expect(h.getBook).toHaveBeenCalledTimes(1);
    expect(h.getChapters).toHaveBeenCalledTimes(1);
  });

  it("正文按「书:章」缓存，不同书/章互不影响", async () => {
    h.getContent.mockImplementation((_id: number, i: number) =>
      Promise.resolve({ title: `第${i}章`, html: "x" }),
    );
    const s = useBookDataStore();

    await s.getContent(1, 0);
    await s.getContent(1, 0);
    await s.getContent(1, 1);
    await s.getContent(2, 0);

    expect(h.getContent).toHaveBeenCalledTimes(3);
    expect(h.getContent).toHaveBeenNthCalledWith(2, 1, 1);
    expect(h.getContent).toHaveBeenNthCalledWith(3, 2, 0);
  });

  it("进度落盘后 invalidateBook，详情重新拉取，目录不受影响", async () => {
    h.getBook.mockResolvedValue({ id: 1, name: "书", percent: 0 });
    h.getChapters.mockResolvedValue([{ index: 0, title: "第一章" }]);
    const s = useBookDataStore();

    await s.getBook(1);
    s.invalidateBook(1);
    await s.getBook(1);
    await s.getChapters(1);

    expect(h.getBook).toHaveBeenCalledTimes(2);
    expect(h.getChapters).toHaveBeenCalledTimes(1);
  });

  it("refresh 绕过缓存重拉详情与目录，并连带失效正文", async () => {
    h.getBook.mockResolvedValue({ id: 1, name: "书" });
    h.getChapters.mockResolvedValue([{ index: 0, title: "第一章" }]);
    h.getContent.mockResolvedValue({ title: "第一章", html: "x" });
    const s = useBookDataStore();

    // 预热缓存
    await s.getBook(1);
    await s.getChapters(1);
    await s.getContent(1, 0);

    const r = await s.refresh(1);
    expect(r.book.name).toBe("书");
    // 详情/目录都被强制重拉
    expect(h.getBook).toHaveBeenCalledTimes(2);
    expect(h.getChapters).toHaveBeenCalledTimes(2);

    // 正文已连带失效：重新获取会再打一次引擎
    await s.getContent(1, 0);
    expect(h.getContent).toHaveBeenCalledTimes(2);

    // 其它书不受影响
    await s.getContent(2, 0);
    expect(h.getContent).toHaveBeenCalledTimes(3);
  });

  it("超过 TTL 后重新拉取", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-10-31T12:00:00"));
    h.getChapters.mockResolvedValue([{ index: 0, title: "第一章" }]);
    const s = useBookDataStore();

    await s.getChapters(1);
    vi.advanceTimersByTime(BOOK_DATA_TTL - 1000);
    await s.getChapters(1);
    expect(h.getChapters).toHaveBeenCalledTimes(1);

    vi.advanceTimersByTime(2000);
    await s.getChapters(1);
    expect(h.getChapters).toHaveBeenCalledTimes(2);
  });

  it("getChapters 返回空时归一化为数组", async () => {
    h.getChapters.mockResolvedValue(null);
    const s = useBookDataStore();
    const list = await s.getChapters(1);
    expect(list).toEqual([]);
  });
});
