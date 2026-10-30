/**
 * 缓存任务状态。
 *
 * 为什么单独放 store：缓存是后台任务，用户点了「缓存整本」之后会到处乱走
 * （回书架、进别的书、去缓存页），任务进度必须在页面之间共享，
 * 而不是绑在某个组件的生命周期上。事件只订阅一次（App 挂载时 attach）。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { cacheApi } from "@/api/cache";
import type { CacheScopeValue } from "@/api/cache";
import { onCacheProgress } from "@/api/events";
import type { CacheProgressPayload } from "@/api/events";
import type { CacheJob } from "@/types";

/** 任务的轻量视图：后端快照与进度事件都归一到这个结构。 */
export interface CacheJobView {
  bookId: number;
  bookName: string;
  scope: string;
  state: string;
  total: number;
  done: number;
  failed: number;
  message: string;
}

const STATE_RUNNING = "running";

function fromJob(job: CacheJob): CacheJobView {
  return {
    bookId: job.bookId,
    bookName: job.bookName,
    scope: job.scope,
    state: job.state,
    total: job.total,
    done: job.done,
    failed: job.failed,
    message: job.message,
  };
}

function fromProgress(p: CacheProgressPayload): CacheJobView {
  return {
    bookId: p.bookId,
    bookName: p.bookName,
    scope: "",
    state: p.state,
    total: p.total,
    done: p.done,
    failed: p.failed,
    // 事件里的 message 是「最近一条错误」，正常进度用 current 更有信息量。
    message: p.message || p.current,
  };
}

/** 轮询间隔：事件负责「实时」，轮询负责「一定不丢」。 */
const POLL_MS = 1000;

export const useCacheStore = defineStore("cache", () => {
  const jobs = ref<Record<number, CacheJobView>>({});
  let unsubscribe: (() => void) | null = null;
  let pollTimer: ReturnType<typeof setInterval> | null = null;
  let polling = false;

  /** 运行中的任务，按书 id 稳定排序，供全局进度条渲染。 */
  const runningJobs = computed(() =>
    Object.values(jobs.value)
      .filter((j) => j.state === STATE_RUNNING)
      .sort((a, b) => a.bookId - b.bookId),
  );

  /** 订阅后端进度事件（重复调用无副作用）。 */
  function attach() {
    if (unsubscribe) return;
    unsubscribe = onCacheProgress((p) => {
      const prev = jobs.value[p.bookId];
      jobs.value = {
        ...jobs.value,
        [p.bookId]: { ...fromProgress(p), scope: prev?.scope ?? "" },
      };
    });
  }

  function detach() {
    unsubscribe?.();
    unsubscribe = null;
    stopPolling();
  }

  /** 从后端拉一次任务列表（权威状态）。 */
  async function refreshJobs() {
    if (polling) return;
    polling = true;
    try {
      const list = await cacheApi.jobs();
      const next: Record<number, CacheJobView> = {};
      for (const job of list) next[job.bookId] = fromJob(job);
      jobs.value = next;
    } finally {
      polling = false;
    }
  }

  /**
   * 有任务在跑时按秒校准一次状态。
   *
   * 事件订阅会被框架的运行时初始化「顶掉」（首屏挂载早于 runtime 注入时，
   * 注册的是打包副本的注册表，收不到任何事件），表现是进度条永远不出现。
   * 事件能收到就即时刷新，收不到由这里兜底，UI 最多晚一秒。
   */
  function ensurePolling() {
    if (pollTimer !== null) return;
    pollTimer = setInterval(async () => {
      await refreshJobs().catch(() => {});
      if (runningJobs.value.length === 0) stopPolling();
    }, POLL_MS);
  }

  function stopPolling() {
    if (pollTimer === null) return;
    clearInterval(pollTimer);
    pollTimer = null;
  }

  /** 开始缓存。scope 为 Chapters 时用 indexes 指定章节。 */
  async function start(
    bookId: number,
    scope: CacheScopeValue,
    indexes: number[] = [],
  ): Promise<CacheJobView> {
    const job = await cacheApi.start(bookId, scope, indexes);
    const view = fromJob(job);
    jobs.value = { ...jobs.value, [bookId]: view };
    ensurePolling();
    return view;
  }

  /** 取消该书的缓存任务。 */
  async function cancel(bookId: number) {
    await cacheApi.cancel(bookId);
  }

  function jobOf(bookId: number): CacheJobView | null {
    return jobs.value[bookId] ?? null;
  }

  function isRunning(bookId: number): boolean {
    return jobOf(bookId)?.state === STATE_RUNNING;
  }

  return {
    jobs,
    runningJobs,
    attach,
    detach,
    refreshJobs,
    start,
    cancel,
    jobOf,
    isRunning,
    ensurePolling,
    stopPolling,
  };
});

/** 任务进度百分比（0~100）。 */
export function jobPercent(job: CacheJobView | null): number {
  if (!job || job.total <= 0) return 0;
  return Math.min(100, Math.round(((job.done + job.failed) / job.total) * 100));
}
