import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * 会话 store 的单测。
 *
 * 事件订阅与后端接口整体替换掉：一是单测不该加载 Wails 绑定，
 * 二是这样能直接拿到回调，按真实时序驱动流式逻辑（顺序、乱序、丢片）。
 */
const h = vi.hoisted(() => ({
  handlers: {} as { chunk?: (p: any) => void; done?: (p: any) => void },
  ask: vi.fn(),
  stop: vi.fn(),
  getMessages: vi.fn(),
}));

vi.mock("@/api/events", () => ({
  onAIAnswerChunk: (fn: (p: any) => void) => {
    h.handlers.chunk = fn;
    return () => {
      h.handlers.chunk = undefined;
    };
  },
  onAIAnswerDone: (fn: (p: any) => void) => {
    h.handlers.done = fn;
    return () => {
      h.handlers.done = undefined;
    };
  },
}));

vi.mock("@/api/ai", () => ({
  aiApi: {
    ask: (...a: unknown[]) => h.ask(...a),
    stopAnswer: (...a: unknown[]) => h.stop(...a),
    getMessages: (...a: unknown[]) => h.getMessages(...a),
    listChats: vi.fn(async () => []),
    createChat: vi.fn(),
    deleteChat: vi.fn(),
  },
}));

import { useAIChatStore } from "./aiChat";

beforeEach(() => {
  setActivePinia(createPinia());
  h.handlers = {};
  h.ask.mockReset();
  h.stop.mockReset();
  h.getMessages.mockReset();
});

/** 取一个已 attach 的 store（模拟 App 挂载时订阅事件）。 */
function attachedStore() {
  const store = useAIChatStore();
  store.attach();
  return store;
}

describe("aiChat 流式合并", () => {
  it("按序追加分片，合成一条 pending 助手消息", () => {
    const store = attachedStore();

    h.handlers.chunk?.({ chatId: 1, delta: "你", seq: 1 });
    h.handlers.chunk?.({ chatId: 1, delta: "好", seq: 2 });

    const list = store.messagesOf(1);
    expect(list).toHaveLength(1);
    expect(list[0].role).toBe("assistant");
    expect(list[0].content).toBe("你好");
    expect(list[0].pending).toBe(true);
    expect(store.isStreaming(1)).toBe(true);
  });

  it("丢弃重复与乱序的分片", () => {
    const store = attachedStore();

    h.handlers.chunk?.({ chatId: 1, delta: "第一", seq: 1 });
    h.handlers.chunk?.({ chatId: 1, delta: "第二", seq: 3 });
    // 迟到与重发都不该再拼进去。
    h.handlers.chunk?.({ chatId: 1, delta: "迟到", seq: 2 });
    h.handlers.chunk?.({ chatId: 1, delta: "第二", seq: 3 });

    expect(store.messagesOf(1)[0].content).toBe("第一第二");
  });

  it("各会话的去重互不干扰", () => {
    const store = attachedStore();

    h.handlers.chunk?.({ chatId: 1, delta: "A", seq: 1 });
    h.handlers.chunk?.({ chatId: 2, delta: "B", seq: 1 });

    expect(store.messagesOf(1)[0].content).toBe("A");
    expect(store.messagesOf(2)[0].content).toBe("B");
  });

  it("结束事件用完整正文覆盖，丢片也不残缺", () => {
    const store = attachedStore();

    h.handlers.chunk?.({ chatId: 1, delta: "开头", seq: 1 });
    h.handlers.chunk?.({ chatId: 1, delta: "结尾", seq: 9 });
    h.handlers.done?.({
      chatId: 1,
      state: "done",
      content: "开头（中间漏了两片）结尾",
      refs: [{ chapterIdx: 1, title: "第一章", excerpt: "片段" }],
      error: "",
      note: "",
    });

    const list = store.messagesOf(1);
    expect(list).toHaveLength(1);
    expect(list[0].content).toBe("开头（中间漏了两片）结尾");
    expect(list[0].refs).toHaveLength(1);
    expect(list[0].pending).toBe(false);
    expect(store.isStreaming(1)).toBe(false);
    expect(store.statusOf(1)?.state).toBe("done");
  });

  it("一个字都没生成时不留空气泡，但保留失败原因", () => {
    const store = attachedStore();

    h.handlers.done?.({
      chatId: 1,
      state: "failed",
      content: "   ",
      refs: [],
      error: "401 鉴权失败",
      note: "",
    });

    expect(store.messagesOf(1)).toHaveLength(0);
    expect(store.statusOf(1)?.state).toBe("failed");
    expect(store.statusOf(1)?.error).toContain("401");
  });

  it("写空的结束事件不会凭空造一条助手消息", () => {
    const store = attachedStore();

    h.handlers.done?.({ chatId: 1, state: "done", content: "", refs: [], error: "", note: "" });

    expect(store.messagesOf(1)).toHaveLength(0);
  });

  it("空分片不建立气泡", () => {
    const store = attachedStore();

    h.handlers.chunk?.({ chatId: 1, delta: "", seq: 1 });

    expect(store.messagesOf(1)).toHaveLength(0);
    expect(store.isStreaming(1)).toBe(false);
  });
});

describe("aiChat 提问", () => {
  it("先把提问本地入列，不等后端往返", async () => {
    const store = useAIChatStore();
    h.ask.mockResolvedValue(undefined);

    await store.ask(1, "  这本书讲了什么  ");

    const list = store.messagesOf(1);
    expect(list).toHaveLength(1);
    expect(list[0].role).toBe("user");
    expect(list[0].content).toBe("这本书讲了什么");
    expect(store.isStreaming(1)).toBe(true);
    expect(h.ask).toHaveBeenCalledWith(1, "这本书讲了什么");

    // 收尾，避免兜底轮询的定时器继续跑。
    h.handlers.chunk?.({ chatId: 1, delta: "答", seq: 1 });
    h.handlers.done?.({ chatId: 1, state: "done", content: "答", refs: [], error: "", note: "" });
  });

  it("空提问不发请求", async () => {
    const store = useAIChatStore();

    await store.ask(1, "   ");

    expect(h.ask).not.toHaveBeenCalled();
    expect(store.messagesOf(1)).toHaveLength(0);
  });

  it("提问发不出去时标记失败并如实抛出", async () => {
    const store = useAIChatStore();
    h.ask.mockRejectedValue(new Error("连接超时"));

    await expect(store.ask(1, "在吗")).rejects.toThrow("连接超时");

    expect(store.isStreaming(1)).toBe(false);
    expect(store.statusOf(1)?.state).toBe("failed");
    expect(store.statusOf(1)?.error).toBe("连接超时");
  });
});

describe("aiChat 订阅生命周期", () => {
  it("重复 attach 不会重复订阅，detach 后不再收事件", () => {
    const store = useAIChatStore();
    store.attach();
    const first = h.handlers.chunk;
    store.attach();
    expect(h.handlers.chunk).toBe(first);

    store.detach();
    expect(h.handlers.chunk).toBeUndefined();
    expect(h.handlers.done).toBeUndefined();
  });
});
