/** 书籍导入导出 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/libraryapi";
import { call } from "./client";

export const libraryApi = {
  /**
   * 导入本地书籍。
   * 返回部分成功语义的结果：个别文件失败不中断整体。
   */
  importFiles: (paths: string[], groupId: number) =>
    call(binding.ImportFiles(paths, groupId)),

  /** 导出书籍；format 取值 epub | txt。 */
  exportBook: (bookId: number, format: string, destPath = "") =>
    call(binding.ExportBook(bookId, format, destPath)),
};
