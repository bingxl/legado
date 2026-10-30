// 书源调试的输出与状态。
//
// 放在 store 而不是页面里，有两个原因：
// 1. 调试一次要几十秒，用户会切到别的标签页看字段，切回来时日志不能丢；
// 2. 事件订阅只挂一次，比每个组件挂一份更省，也不会漏掉先到的几条。
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import {
  onSourceDebug,
  onSourceDebugDone,
  type SourceDebugEntryPayload,
} from "@/api/events";
import { sourceDebugApi, type DebugStageValue } from "@/api/sourcedebug";

/** 输出面板里的一行。 */
export interface DebugLine {
  id: number;
  /** 相对调试起点的毫秒数，用于生成 [mm:ss.SSS] */
  elapsedMs: number;
  /** log / error / list / info / toc / content / done */
  kind: string;
  msg: string;
  /** 响应体行：默认折叠，点开看全文（后端已截断到 4KB） */
  collapsible: boolean;
  expanded: boolean;
}

/** 本地保留的最大行数，防止书源里的死循环 js 把页面撑爆。 */
const MAX_LINES = 3000;

function formatElapsed(ms: number): string {
  const total = Math.max(0, ms);
  const minute = Math.floor(total / 60000);
  const second = Math.floor((total % 60000) / 1000);
  const milli = Math.floor(total % 1000);
  return `${String(minute).padStart(2, "0")}:${String(second).padStart(2, "0")}.${String(milli).padStart(3, "0")}`;
}

/** 调试入口的形态，决定后端从哪一步开始。 */
export const DebugEntryKind = {
  Search: "search",
  Detail: "detail",
  Explore: "explore",
  Toc: "toc",
  Content: "content",
} as const;

export type DebugEntryKindValue =
  (typeof DebugEntryKind)[keyof typeof DebugEntryKind];

let attached = false;

export const useSourceDebugStore = defineStore("sourceDebug", () => {
  const lines = ref<DebugLine[]>([]);
  const running = ref(false);
  const session = ref("");
  const failed = ref(false);
  const finished = ref(false);
  const reason = ref("");
  const elapsedMs = ref(0);
  const autoScroll = ref(true);

  let seq = 0;

  const hasOutput = computed(() => lines.value.length > 0);

  /** 状态行文案。 */
  const statusText = computed(() => {
    if (running.value) return "调试中…";
    if (!finished.value) return "尚未调试";
    if (failed.value) return `调试失败${reason.value ? "：" + reason.value : ""}`;
    return "调试完成";
  });

  function pushLine(e: SourceDebugEntryPayload): void {
    const kind = e.stateName || "log";
    lines.value.push({
      id: ++seq,
      elapsedMs: e.elapsedMs,
      kind,
      msg: e.msg,
      collapsible: kind === "list" || kind === "info" || kind === "toc" || kind === "content",
      expanded: false,
    });
    if (lines.value.length > MAX_LINES) {
      lines.value.splice(0, lines.value.length - MAX_LINES);
    }
  }

  /** 挂上事件订阅（幂等）。 */
  function attach(): void {
    if (attached) return;
    attached = true;
    onSourceDebug((e) => {
      // 会话被顶替后，旧会话的残余打点不该混进新输出。
      if (session.value && e.session && e.session !== session.value) return;
      pushLine(e);
    });
    onSourceDebugDone((d) => {
      if (session.value && d.session && d.session !== session.value) return;
      running.value = false;
      finished.value = true;
      failed.value = d.failed;
      reason.value = d.reason || "";
      elapsedMs.value = d.elapsedMs;
    });
  }

  /** 开始调试。raw 传草稿，允许没保存就试规则。 */
  async function start(
    sourceID: number,
    raw: string,
    key: string,
    stage: DebugStageValue,
  ): Promise<void> {
    attach();
    lines.value = [];
    failed.value = false;
    finished.value = false;
    reason.value = "";
    elapsedMs.value = 0;
    running.value = true;
    try {
      const view = await sourceDebugApi.start(sourceID, raw, key, stage);
      session.value = view.session;
    } catch (e) {
      running.value = false;
      finished.value = true;
      failed.value = true;
      reason.value = (e as Error).message;
      throw e;
    }
  }

  async function stop(): Promise<void> {
    try {
      await sourceDebugApi.stop();
    } finally {
      reason.value = "已停止";
    }
  }

  function clear(): void {
    lines.value = [];
    finished.value = false;
    failed.value = false;
    reason.value = "";
    elapsedMs.value = 0;
  }

  function toggleLine(id: number): void {
    const line = lines.value.find((l) => l.id === id);
    if (line) line.expanded = !line.expanded;
  }

  return {
    lines,
    running,
    session,
    failed,
    finished,
    reason,
    elapsedMs,
    autoScroll,
    hasOutput,
    statusText,
    attach,
    start,
    stop,
    clear,
    toggleLine,
    formatElapsed,
  };
});
