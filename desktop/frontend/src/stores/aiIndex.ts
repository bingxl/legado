/**
 * AI 索引任务状态。
 *
 * 为什么单独放 store：索引是后台长任务（整本可能几十分钟），用户点完「生成」
 * 会到处走（回书架、去别的书），状态必须跨页面共享，而不是绑在某个组件的
 * 生命周期上。事件只订阅一次（App 挂载时 attach）。
 *
 * 与缓存 store 同一套手法：事件负责「实时」，轮询负责「一定不丢」。
 * 事件订阅在首屏可能被运行时初始化顶掉（详见 src/api/events.ts），
 * 没有轮询兜底时表现为进度条永远不动。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { aiApi } from "@/api/ai";
import { onAIIndexProgress } from "@/api/events";
import type { AIIndexProgressPayload } from "@/api/events";
import type { AIIndexStatusView } from "@/api/ai";

const STATE_RUNNING = "running";

/** 终态不会再自行变化，直到下一次 start。 */
function isTerminal(status: string | undefined): boolean {
  return status === "done" || status === "failed" || status === "canceled";
}

/** 进度百分比取「当前阶段」的完成度：各阶段的分母不同，不能跨阶段累加。 */
export function indexPercent(view: AIIndexStatusView | null): number {
  if (!view) return 0;
  if (view.status === "done") return 100;
  if (view.summaryTotal > 0) {
    return Math.min(
      100,
      Math.round((view.summaryDone / view.summaryTotal) * 100),
    );
  }
  return 0;
}

/** 阶段的中文名，供进度文案使用。 */
export function phaseLabel(phase: string): string {
  switch (phase) {
    case "fetch":
      return "读取正文";
    case "chunk":
      return "切分正文";
    case "embed":
      return "生成向量";
    case "summary":
      return "生成摘要";
    case "done":
      return "完成";
    case "failed":
      return "失败";
    case "canceled":
      return "已取消";
    default:
      return "";
  }
}

/** 轮询间隔：事件负责「实时」，轮询负责「一定不丢」。 */
const POLL_MS = 1000;

export const useAIIndexStore = defineStore("aiIndex", () => {
  /** 按书籍 id 缓存状态。 */
  const statuses = ref<Record<number, AIIndexStatusView>>({});
  /** 最近一次事件带来的阶段与文案（快照里没有这两个字段）。 */
  const phases = ref<Record<number, { phase: string; message: string }>>({});
  /** 每本书已应用的最大事件序号，用于丢弃迟到的旧事件。 */
  const lastSeq = new Map<number, number>();

  let unsubscribe: (() => void) | null = null;
  let pollTimer: ReturnType<typeof setInterval> | null = null;
  let polling = false;

  const runningIds = computed(() =>
    Object.values(statuses.value)
      .filter((s) => s.status === STATE_RUNNING)
      .map((s) => s.bookId)
      .sort((a, b) => a - b),
  );

  function attach() {
    if (unsubscribe) return;
    unsubscribe = onAIIndexProgress((p: AIIndexProgressPayload) => {
      applyProgress(p);
    });
  }

  function detach() {
    unsubscribe?.();
    unsubscribe = null;
    stopPolling();
  }

  /** 把进度事件并入状态。 */
  function applyProgress(p: AIIndexProgressPayload) {
    // 事件异步投递，可能乱序到达。终态之后再来一个早阶段的 embed/summary 事件，
    // 界面就会从「索引已就绪」翻回「索引进行中」——按钮也跟着从「删除索引」
    // 变成「取消索引」。所以按序号丢弃过期事件；
    // fetch 是新任务的起点，允许它重置基准（否则进程重启后序号归零会把新事件全丢掉）。
    const seq = p.seq ?? 0;
    if (p.phase === "fetch") {
      lastSeq.delete(p.bookId);
    } else if (seq > 0 && seq <= (lastSeq.get(p.bookId) ?? 0)) {
      return;
    }
    if (seq > 0) lastSeq.set(p.bookId, seq);

    phases.value = {
      ...phases.value,
      [p.bookId]: { phase: p.phase, message: p.message },
    };

    const prev = statuses.value[p.bookId];
    const next: AIIndexStatusView = {
      ...(prev ?? { bookId: p.bookId }),
      bookId: p.bookId,
      status: phaseToStatus(p.phase, prev?.status ?? "idle"),
    } as AIIndexStatusView;

    // 摘要阶段的分母只在该阶段有效，其它阶段保留原值。
    if (p.phase === "summary" && p.total > 0) {
      next.summaryDone = p.done;
      next.summaryTotal = p.total;
    }
    statuses.value = { ...statuses.value, [p.bookId]: next };

    if (next.status === STATE_RUNNING) {
      ensurePolling();
    } else if (isTerminal(next.status)) {
      // 终态事件只说明「跑完了」，不带切片数与摘要，而这些字段此刻还是
      // 任务开始时的旧值（chunkCount 常为 0）。轮询又随终态停止，不补这一次
      // 快照就会停在「索引已就绪 · 0 片」且没有摘要。后端是先落库再发事件，
      // 所以这次取到的一定是终态值。
      void refresh(p.bookId);
    }
  }

  /** 事件只告诉「进行到哪」，切片数/摘要内容仍要回后端取权威值。 */
  async function refresh(bookId: number): Promise<AIIndexStatusView | null> {
    if (!bookId) return null;
    try {
      const st = await aiApi.indexStatus(bookId);
      // 快照也是异步的：一个在任务结束前发出的轮询可能晚于终态事件返回。
      // 用旧快照覆盖终态会让「已就绪」闪回「进行中」，因此不能降级；
      // 新任务由 start() 直接把状态置为 running，不依赖这条路径。
      if (st.status === STATE_RUNNING && isTerminal(statuses.value[bookId]?.status)) {
        return statuses.value[bookId] ?? null;
      }
      statuses.value = { ...statuses.value, [bookId]: st };
      if (st.status === STATE_RUNNING) ensurePolling();
      return st;
    } catch {
      return statuses.value[bookId] ?? null;
    }
  }

  function ensurePolling() {
    if (pollTimer !== null) return;
    pollTimer = setInterval(async () => {
      for (const id of runningIds.value) await refresh(id);
      if (runningIds.value.length === 0) stopPolling();
    }, POLL_MS);
  }

  function stopPolling() {
    if (pollTimer === null) return;
    clearInterval(pollTimer);
    pollTimer = null;
  }

  /** 启动索引；返回后端给的初始状态。 */
  async function start(
    bookId: number,
    scope: string,
    from = 0,
    to = 0,
  ): Promise<AIIndexStatusView> {
    const st = await aiApi.startIndex(
      bookId,
      scope as never,
      Math.max(0, from),
      Math.max(0, to),
    );
    statuses.value = { ...statuses.value, [bookId]: st };
    phases.value = {
      ...phases.value,
      [bookId]: { phase: "fetch", message: "准备索引" },
    };
    // 新任务：丢掉上一轮的事件基准，避免序号比较把本轮事件误判为过期。
    lastSeq.delete(bookId);
    ensurePolling();
    return st;
  }

  async function cancel(bookId: number) {
    await aiApi.cancelIndex(bookId);
    await refresh(bookId);
  }

  async function remove(bookId: number) {
    await aiApi.deleteIndex(bookId);
    const next = { ...statuses.value };
    delete next[bookId];
    statuses.value = next;
    await refresh(bookId);
  }

  function statusOf(bookId: number): AIIndexStatusView | null {
    return statuses.value[bookId] ?? null;
  }

  function phaseOf(bookId: number) {
    return phases.value[bookId] ?? null;
  }

  function isRunning(bookId: number): boolean {
    return statusOf(bookId)?.status === STATE_RUNNING;
  }

  return {
    statuses,
    runningIds,
    attach,
    detach,
    refresh,
    start,
    cancel,
    remove,
    statusOf,
    phaseOf,
    isRunning,
    ensurePolling,
    stopPolling,
  };
});

/**
 * 进度事件映射到状态。
 *
 * 后端在任务结束时只推一个终态事件、随后把状态落库，因此这里必须把
 * done/failed/canceled 直接当状态用，否则界面会停在「进行中」等下一次轮询。
 */function phaseToStatus(phase: string, prev: string): string {
  switch (phase) {
    case "done":
      return "done";
    case "failed":
      return "failed";
    case "canceled":
      return "canceled";
    case "fetch":
    case "chunk":
    case "embed":
    case "summary":
      return STATE_RUNNING;
    default:
      return prev;
  }
}
