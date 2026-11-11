/** 词典取词与词库管理 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/dictapi";
import { call, callList } from "./client";

export type {
  DictEntryView,
  DictPackageView,
  DictProbeView,
  DictResultView,
  DictSourceConfigView,
  DictSourceView,
  DictStatusView,
} from "@bindings/github.com/legado/desktop/internal/app/dto/models";

export const dictApi = {
  /**
   * 查词。hint 取 auto / en / zh。
   *
   * 长度闸门在后端（200 字符）：前端误把整章传进来时会拿到可读的错误，
   * 而不是把几十 KB 打到词库上。
   */
  lookup: (text: string, hint: "auto" | "en" | "zh" = "auto") =>
    call(binding.Lookup(text, hint)),

  /** 各词库包的就位状态。 */
  status: () => call(binding.DictStatus()),

  /** 针对某个包过滤后的下载源列表（含不可用原因）。 */
  sources: (packId: string) => callList(binding.DictSources(packId)),

  /** 当前下载源配置，带「最终会请求哪个地址」的回显。 */
  sourceConfig: (packId: string) => call(binding.GetDictSource(packId)),

  /** 预演某组配置会请求哪个地址（不发网络请求）。 */
  preview: (packId: string, sourceId: string, customUrl: string) =>
    call(binding.PreviewDictSource(packId, sourceId, customUrl)),

  /** 保存下载源配置。 */
  setSource: (mode: "auto" | "manual", sourceId: string, customUrl: string) =>
    call(binding.SetDictSource(mode, sourceId, customUrl)),

  /** 64 KB Range 探测，服务端不缓存结果。 */
  probe: (packId: string, sourceId: string, customUrl = "") =>
    call(binding.ProbeDictSource(packId, sourceId, customUrl)),

  /** 开始安装；立即返回，进度走 dict:install:progress 事件。 */
  install: (packId: string, sourceId = "", customUrl = "") =>
    call(binding.InstallDict(packId, sourceId, customUrl)),

  /** 换源重试，保留已下载的字节。 */
  retry: (packId: string, sourceId = "", customUrl = "") =>
    call(binding.RetryInstall(packId, sourceId, customUrl)),

  /** 取消安装并清理半截文件。 */
  cancel: (packId: string) => call(binding.CancelInstall(packId)),

  /** 删除扩展包（内置核心会被拒绝）。 */
  remove: (packId: string) => call(binding.RemoveDict(packId)),

  /** 用本地文件安装（path 由系统文件对话框取得）。 */
  importFile: (packId: string, path: string) =>
    call(binding.ImportDictFile(packId, path)),
};
