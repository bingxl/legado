/** 阅读器 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/readerapi";
import { call, callList } from "./client";

export const readerApi = {
  /** 目录。 */
  getChapters: (bookId: number) => callList(binding.GetChapters(bookId)),

  /** 章节正文。 */
  getContent: (bookId: number, index: number) =>
    call(binding.GetContent(bookId, index)),

  /** 保存进度。 */
  saveProgress: (
    bookId: number,
    chapterIndex: number,
    chapterTitle: string,
    chapterPos: number,
    scrollPercent: number,
  ) =>
    call(
      binding.SaveProgress(
        bookId,
        chapterIndex,
        chapterTitle,
        chapterPos,
        scrollPercent,
      ),
    ),

  /** 上次阅读位置；无记录时 chapterIndex 为 -1。 */
  getProgress: (bookId: number) => call(binding.GetProgress(bookId)),

  /** 回写目录（PDF 大纲由前端解析后回传）。 */
  syncOutline: (bookId: number, items: Parameters<typeof binding.SyncOutline>[1]) =>
    call(binding.SyncOutline(bookId, items)),
};
