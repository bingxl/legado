import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * 索引 store 的单测。
 *
 * 重点是**乱序保护**：进度事件经前端运行时异步投递，到达顺序与产生顺序无关。
 * 早期实现直接并入状态，于是终态之后迟到的 embed 事件会把界面从
 * 「索引已就绪」翻回「索引进行中」，按钮也从「删除索引」变成「取消索引」。
 */
const h = vi.hoisted(() => ({
  handlers: {} as { progress?: (p: any) => void },
  startIndex: vi.fn(),
  indexStatus: vi.fn(),
  cancelIndex: vi.fn(),
  deleteIndex: vi.fn(),
}));

vi.mock("@/api/events", () => ({
  onAIIndexProgress: (fn: (p: any) => void) => {
    h.handlers.progress = fn;
    return () => {
      h.handlers.progress = undefined;
    };
  },
}));

vi.mock("@/api/ai", () => ({
  aiApi: {
    startIndex: (...a: unknown[]) => h.startIndex(...a),
    indexStatus: (...a: unknown[]) => h.indexStatus(...a),
    cancelIndex: (...a: unknown[]) => h.cancelIndex(...a),
    deleteIndex: (...a: unknown[]) => h.deleteIndex(...a),
  },
}));

import { indexPercent, useAIIndexStore } from "./aiIndex";

/** 造一条进度事件。 */
function ev(phase: string, seq: number, done = 0, total = 0) {
  return { bookId: 7, phase, done, total, message: phase, seq };
}

function attachedStore() {
  const store = useAIIndexStore();
  store.attach();
  store.stopPolling();
  return store;
}

beforeEach(() => {
  setActivePinia(createPinia());
  h.handlers = {};
  h.startIndex.mockReset();
  h.indexStatus.mockReset();
  h.cancelIndex.mockReset();
  h.deleteIndex.mockReset();
});

describe("aiIndex 事件顺序", () => {
  it("按序号推进阶段", () => {
    const store = attachedStore();

    h.handlers.progress?.(ev("fetch", 1));
    expect(store.statusOf(7)?.status).toBe("running");
    h.handlers.progress?.(ev("done", 2));
    expect(store.statusOf(7)?.status).toBe("done");
  });

  it("终态之后迟到的旧事件不会把状态打回进行中", () => {
    const store = attachedStore();
    h.handlers.progress?.(ev("embed", 5));
    h.handlers.progress?.(ev("done", 6));

    // 迟到的早阶段事件（序号更小）
    h.handlers.progress?.(ev("embed", 4));
    h.handlers.progress?.(ev("summary", 3, 1, 2));

    expect(store.statusOf(7)?.status).toBe("done");
    expect(store.phaseOf(7)?.phase).toBe("done");
  });

  it("新任务的 fetch 事件重置序号基准", () => {
    const store = attachedStore();
    h.handlers.progress?.(ev("done", 99));

    // 后端重启后序号从 1 重新开始，必须仍能推进。
    h.handlers.progress?.(ev("fetch", 1));
    expect(store.statusOf(7)?.status).toBe("running");
    h.handlers.progress?.(ev("embed", 2));
    expect(store.phaseOf(7)?.phase).toBe("embed");
  });

  it("序号缺失时按旧行为直接并入", () => {
    const store = attachedStore();

    h.handlers.progress?.({ ...ev("chunk", 0), seq: undefined });

    expect(store.statusOf(7)?.status).toBe("running");
  });

  it("终态事件后回后端补一次快照（切片数与摘要不在事件里）", async () => {
    const store = attachedStore();
    h.handlers.progress?.(ev("fetch", 1));
    h.indexStatus.mockResolvedValue({
      bookId: 7,
      status: "done",
      chunkCount: 200,
      vectorCount: 200,
      summaryDone: 23,
      summaryTotal: 23,
      summary: "这是摘要",
      error: "",
    });

    h.handlers.progress?.(ev("done", 2));
    await new Promise((r) => setTimeout(r, 0));

    expect(h.indexStatus).toHaveBeenCalledWith(7);
    expect(store.statusOf(7)?.chunkCount).toBe(200);
    expect(store.statusOf(7)?.summary).toBe("这是摘要");
    store.stopPolling();
  });
});

describe("aiIndex 快照不降级", () => {
  it("终态不会被任务结束前发出的旧快照覆盖", async () => {
    const store = attachedStore();
    h.handlers.progress?.(ev("done", 8));

    h.indexStatus.mockResolvedValue({
      bookId: 7,
      status: "running",
      chunkCount: 120,
      vectorCount: 60,
      summaryDone: 0,
      summaryTotal: 0,
      summary: "",
      error: "",
    });
    await store.refresh(7);

    expect(store.statusOf(7)?.status).toBe("done");
  });

  it("第一次打开页面时 running 快照正常生效", async () => {
    const store = attachedStore();
    h.indexStatus.mockResolvedValue({
      bookId: 7,
      status: "running",
      chunkCount: 120,
      vectorCount: 60,
      summaryDone: 3,
      summaryTotal: 6,
      summary: "",
      error: "",
    });

    await store.refresh(7);

    expect(store.statusOf(7)?.status).toBe("running");
    expect(indexPercent(store.statusOf(7))).toBe(50);
    store.stopPolling();
  });
});
