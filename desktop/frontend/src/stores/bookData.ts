// 书籍数据缓存：详情 / 目录 / 章节正文。
//
// 详情页 ↔ 阅读器来回切换时，每次都要重拉 getBook + getChapters，
// 阅读器每章还要 getContent——网络书走书源引擎，感知很明显。
// 改成 store 里按书缓存一份，页面间共享（思路同 sources.ts）：
// - 详情 / 目录 / 正文都带 TTL：书源更新后章节和内容会变，超时重新拉取；
// - 阅读进度落盘后失效详情（进度字段变了，详情页要看到新的）；
// - 手动刷新绕过缓存强制重拉，并连带失效这本书的正文缓存。
//
// 约定：store 只做「数据持有 + 调用 src/api」，不掺杂 UI 交互（同 bookshelf）。
import { defineStore } from "pinia";

import { bookshelfApi } from "@/api/bookshelf";
import { readerApi } from "@/api/reader";
import type { BookDetail, ChapterContent, ChapterItem } from "@/types";

/** 目录与正文的缓存有效期。 */
export const BOOK_DATA_TTL = 10 * 60 * 1000;

interface Entry<T> {
  data: T;
  at: number;
}

function fresh<T>(e: Entry<T> | undefined, now: number): e is Entry<T> {
  return !!e && now - e.at < BOOK_DATA_TTL;
}

export const useBookDataStore = defineStore("bookData", () => {
  // 纯缓存，无需响应式：调用方拿到数据后自会放进自己的 ref。
  const books = new Map<number, Entry<BookDetail>>();
  const chapterLists = new Map<number, Entry<ChapterItem[]>>();
  // key 为 `${bookId}:${index}`；整书失效时按前缀清理。
  const contents = new Map<string, Entry<ChapterContent>>();

  /** 书籍详情。force 时绕过缓存重拉。 */
  async function getBook(id: number, force = false): Promise<BookDetail> {
    const now = Date.now();
    if (!force) {
      const hit = books.get(id);
      if (fresh(hit, now)) return hit.data;
    }
    const data = await bookshelfApi.getBook(id);
    books.set(id, { data, at: now });
    return data;
  }

  /** 目录。force 时绕过缓存重拉。 */
  async function getChapters(id: number, force = false): Promise<ChapterItem[]> {
    const now = Date.now();
    if (!force) {
      const hit = chapterLists.get(id);
      if (fresh(hit, now)) return hit.data;
    }
    const data = (await readerApi.getChapters(id)) ?? [];
    chapterLists.set(id, { data, at: now });
    return data;
  }

  /** 章节正文，按「书:章」缓存。force 时绕过缓存重拉。 */
  async function getContent(
    id: number,
    index: number,
    force = false,
  ): Promise<ChapterContent> {
    const key = `${id}:${index}`;
    const now = Date.now();
    if (!force) {
      const hit = contents.get(key);
      if (fresh(hit, now)) return hit.data;
    }
    const data = await readerApi.getContent(id, index);
    contents.set(key, { data, at: now });
    return data;
  }

  /** 阅读进度已落盘：详情展示的进度字段失效，下次进详情重新拉。 */
  function invalidateBook(id: number) {
    books.delete(id);
  }

  /** 这本书的正文全部失效（目录重拉后章节序号可能整体变化）。 */
  function invalidateContents(id: number) {
    const prefix = `${id}:`;
    for (const k of [...contents.keys()]) {
      if (k.startsWith(prefix)) contents.delete(k);
    }
  }

  /** 手动刷新：绕过缓存重拉详情与目录，并连带失效这本书的正文缓存。 */
  async function refresh(
    id: number,
  ): Promise<{ book: BookDetail; chapters: ChapterItem[] }> {
    const [book, chapters] = await Promise.all([
      getBook(id, true),
      getChapters(id, true),
    ]);
    invalidateContents(id);
    return { book, chapters };
  }

  return { getBook, getChapters, getContent, invalidateBook, refresh };
});
