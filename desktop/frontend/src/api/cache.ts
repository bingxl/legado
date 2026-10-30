/**
 * 章节缓存 API。
 *
 * 缓存是**手动触发**的：所有写盘动作都来自这里的 start 调用，
 * 阅读本身不会偷偷缓存内容。任务在后端异步执行，进度通过
 * `onCacheProgress` 事件推送。
 */
import * as binding from "@bindings/github.com/legado/desktop/api/cacheapi";
import { call, callList } from "./client";

/** 缓存范围（与后端 dto.CacheScope* 保持一致）。 */
export const CacheScope = {
  /** 整本 */
  All: "all",
  /** 从当前阅读位置到结尾 */
  Remaining: "remaining",
  /** 只补尚未缓存的章节 */
  Missing: "missing",
  /** 指定章节（「缓存本章」用） */
  Chapters: "chapters",
} as const;

export type CacheScopeValue = (typeof CacheScope)[keyof typeof CacheScope];

export const cacheApi = {
  /** 全局缓存统计（书数 / 章数 / 占用 / 运行中任务数）。 */
  stats: () => call(binding.Stats()),

  /** 有缓存的书。 */
  books: () => callList(binding.Books()),

  /** 某本书已缓存的章节明细。 */
  chapters: (bookId: number) => callList(binding.Chapters(bookId)),

  /** 某本书的缓存概况。 */
  status: (bookId: number) => call(binding.Status(bookId)),

  /** 全部缓存任务（含已结束的）。 */
  jobs: () => callList(binding.Jobs()),

  /** 开始缓存；indexes 仅在 scope 为 chapters 时生效。 */
  start: (bookId: number, scope: CacheScopeValue, indexes: number[] = []) =>
    call(binding.Start(bookId, scope, indexes)),

  /** 取消某本书正在进行的缓存。 */
  cancel: (bookId: number) => call(binding.Cancel(bookId)),

  /** 删除指定章节的缓存。 */
  deleteChapters: (bookId: number, indexes: number[]) =>
    call(binding.DeleteChapters(bookId, indexes)),

  /** 清空某本书的全部缓存。 */
  purgeBook: (bookId: number) => call(binding.PurgeBook(bookId)),

  /** 清空全部缓存。 */
  clear: () => call(binding.Clear()),
};
