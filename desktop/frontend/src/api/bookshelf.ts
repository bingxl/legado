/**
 * 书架 API。
 *
 * 防腐层：本目录是**唯一**允许引用 `@bindings` 的地方（ARCHITECTURE.md R4）。
 * 对外统一用 camelCase 命名，屏蔽生成代码的 PascalCase 风格。
 */
import * as binding from "@bindings/github.com/legado/desktop/api/bookshelfapi";
import { call, callList } from "./client";

export const bookshelfApi = {
  /** 列出全部分组。 */
  listGroups: () => callList(binding.ListGroups()),

  /** 列出分组下书籍；groupId 传 0 表示全部。 */
  listBooks: (groupId: number) => callList(binding.ListBooks(groupId)),

  /** 书籍详情。 */
  getBook: (id: number) => call(binding.GetBook(id)),

  /** 删除书籍。 */
  deleteBook: (id: number) => call(binding.DeleteBook(id)),

  /** 移动到分组。 */
  moveToGroup: (bookId: number, groupId: number) =>
    call(binding.MoveToGroup(bookId, groupId)),

  /** 新建分组。 */
  createGroup: (name: string) => call(binding.CreateGroup(name)),

  /** 更新分组。 */
  updateGroup: (id: number, name: string, show: boolean, order: number) =>
    call(binding.UpdateGroup(id, name, show, order)),

  /** 删除分组。 */
  deleteGroup: (id: number) => call(binding.DeleteGroup(id)),
};
