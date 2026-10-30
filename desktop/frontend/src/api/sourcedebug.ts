/** 书源调试 API。
 *
 * 调试是异步的：start 只负责把任务丢给后端并立即返回会话 ID，
 * 真正的输出通过 source:debug / source:debug:done 事件流回来
 * （见 api/events.ts 的 onSourceDebug / onSourceDebugDone）。
 */
import * as binding from "@bindings/github.com/legado/desktop/api/sourcedebugapi";
import { call } from "./client";

/** 调试最深跑到哪一步。 */
export const DebugStage = {
  Search: "search",
  Explore: "explore",
  Info: "info",
  Toc: "toc",
  Content: "content",
} as const;

export type DebugStageValue = (typeof DebugStage)[keyof typeof DebugStage];

export const sourceDebugApi = {
  /**
   * 开始调试。
   *
   * @param sourceId 已保存的书源 ID；传 0 时以 raw 为准
   * @param raw 书源 JSON 草稿（编辑页未保存的修改也能调试）
   * @param key 调试入口：关键字 / 书籍地址 / 分类::地址 / ++目录地址 / --正文地址
   * @param stage 最深执行到哪一步，默认 content
   */
  start: (sourceId: number, raw: string, key: string, stage: DebugStageValue = DebugStage.Content) =>
    call(binding.Start(sourceId, raw, key, stage)),

  /** 停止当前调试（引擎会在当前阶段结束后退出）。 */
  stop: () => call(binding.Stop()),

  /** 查询是否有调试在跑。 */
  running: () => call(binding.Running()),
};
