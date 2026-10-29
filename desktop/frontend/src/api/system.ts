/** 系统能力（文件对话框等）。 */
import * as binding from "@bindings/github.com/legado/desktop/api/systemapi";
import { call, callList } from "./client";

export const systemApi = {
  /** 选择书籍文件；返回路径列表，用户取消时为空数组。 */
  openBooks: () =>
    callList(
      binding.OpenFiles("选择书籍文件", true, [
        "*.epub",
        "*.txt",
        "*.pdf",
        "*.cbz",
        "*.zip",
      ]),
    ),

  /** 选择书源文件（JSON）。 */
  openSourceFile: () =>
    callList(binding.OpenFiles("选择书源文件", false, ["*.json", "*.txt"])),

  /** 选择目录（漫画图片目录）。 */
  openDirectory: (title = "选择目录") => call(binding.OpenDirectory(title)),

  /** 选择保存位置。 */
  saveFile: (title: string, defaultName: string) =>
    call(binding.SaveFile(title, defaultName)),

  /** 把文本写入磁盘（前端无法直接写文件，需经后端落地）。 */
  saveTextFile: (path: string, content: string) =>
    call(binding.SaveTextFile(path, content)),
};

/** 本地文件访问：把磁盘绝对路径转为 WebView 可加载的 URL。 */
export function rawFileURL(absPath: string): string {
  return "/raw/?p=" + encodeURIComponent(absPath);
}
