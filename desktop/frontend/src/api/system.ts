/** 系统能力（文件对话框等）。 */
import * as binding from "@bindings/github.com/legado/desktop/api/systemapi";
import { call, callList } from "./client";

/** 运行平台。目前桌面端与安卓端共用同一套视图，只有外壳布局不同。 */
export type PlatformName = "desktop" | "android";

/** 安全区尺寸（像素），用于刘海屏与系统手势条避让。 */
export interface SafeArea {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

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

  /** 当前运行平台：决定用桌面侧边栏还是移动端底部 Tab。 */
  platform: () => call(binding.Platform()) as Promise<PlatformName>,

  /**
   * 安全区尺寸 JSON。安卓刘海屏/挖孔屏/系统手势条需要据此避让；
   * 桌面端返回空串，调用方按全 0 处理。
   */
  safeArea: async (): Promise<SafeArea> => {
    const raw = await call(binding.SafeArea());
    const zero = { top: 0, bottom: 0, left: 0, right: 0 };
    if (!raw) return zero;
    try {
      const v = JSON.parse(raw) as Partial<SafeArea>;
      return {
        top: Number(v.top) || 0,
        bottom: Number(v.bottom) || 0,
        left: Number(v.left) || 0,
        right: Number(v.right) || 0,
      };
    } catch {
      // 解析失败不该让布局崩掉，按无安全区处理。
      return zero;
    }
  },
};

// 资源地址的构造在 utils/assetUrl.ts（不依赖绑定，可单测）；这里转出，
// 让视图层只从一个地方拿 systemApi 相关的工具。
export { rawFileURL, rawImageURL } from "@/utils/assetUrl";
