/**
 * AI 问答会话状态。
 *
 * 为什么放 store 而不是组件里：回答是流式的，用户可能中途切到书架再回来，
 * 回来时回答应该还在。会话与消息按 chatId 缓存，事件只订阅一次（App 挂载时 attach）。
 *
 * 流式渲染的约定：先插一条 pending 的助手消息，分片往里追加；结束事件用
 * 完整正文覆盖它（服务端是权威值）。这样即使中途丢了几片，最终内容也不会残缺。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { aiApi } from "@/api/ai";
import type { AIChatView } from "@/api/ai";
import { onAIAnswerChunk, onAIAnswerDone } from "@/api/events";
import type { AIRefPayload } from "@/api/events";

/** 界面上的一条消息。 */
export interface ChatMessageView {
  id: number;
  role: "user" | "assistant" | string;
  content: string;
  refs: AIRefPayload[];
  /** 正在流式输出中（还没有最终内容）。 */
  pending: boolean;
}

/** 一次回答的结果提示。 */
export interface AnswerStatus {
  state: string;
  error: string;
  note: string;
}

export const useAIChatStore = defineStore("aiChat", () => {
  /** bookId → 会话列表。 */
  const chats = ref<Record<number, AIChatView[]>>({});
  /** chatId → 消息列表。 */
  const messages = ref<Record<number, ChatMessageView[]>>({});
  /** chatId → 是否正在生成。 */
  const streaming = ref<Record<number, boolean>>({});
  /** chatId → 最近一次结束状态（失败原因 / 降级说明）。 */
  const statuses = ref<Record<number, AnswerStatus>>({});

  /** 已处理的最大分片序号，用于丢弃重复与乱序。 */
  const lastSeq = new Map<number, number>();
  let unsubscribeChunk: (() => void) | null = null;
  let unsubscribeDone: (() => void) | null = null;

  function attach() {
    if (unsubscribeChunk) return;
    unsubscribeChunk = onAIAnswerChunk((p) => applyChunk(p.chatId, p.delta, p.seq));
    unsubscribeDone = onAIAnswerDone((p) => {
      applyDone(p.chatId, p.state, p.content, p.refs ?? [], p.error, p.note);
    });
  }

  function detach() {
    unsubscribeChunk?.();
    unsubscribeDone?.();
    unsubscribeChunk = null;
    unsubscribeDone = null;
  }

  /** 追加一个分片；没有 pending 消息时补一条。 */
  function applyChunk(chatId: number, delta: string, seq: number) {
    if (!delta) return;
    const seen = lastSeq.get(chatId) ?? 0;
    if (seq > 0 && seq <= seen) return; // 重复或乱序
    if (seq > 0) lastSeq.set(chatId, seq);

    const list = messages.value[chatId] ?? [];
    const next = [...list];
    const idx = findPending(next);
    if (idx >= 0) {
      next[idx] = { ...next[idx], content: next[idx].content + delta };
    } else {
      next.push({
        id: -Date.now(),
        role: "assistant",
        content: delta,
        refs: [],
        pending: true,
      });
    }
    messages.value = { ...messages.value, [chatId]: next };
    streaming.value = { ...streaming.value, [chatId]: true };
  }

  /** 结束：用服务端给的完整正文覆盖 pending 消息。 */
  function applyDone(
    chatId: number,
    state: string,
    content: string,
    refs: AIRefPayload[],
    error: string,
    note: string,
  ) {
    const list = [...(messages.value[chatId] ?? [])];
    const idx = findPending(list);
    const final = content.trim();
    if (idx >= 0) {
      if (final) {
        list[idx] = { ...list[idx], content: final, refs, pending: false };
      } else {
        // 一个字都没生成（例如鉴权失败）：撤掉空气泡，别留个空白框。
        list.splice(idx, 1);
      }
    } else if (final) {
      list.push({
        id: -Date.now(),
        role: "assistant",
        content: final,
        refs,
        pending: false,
      });
    }
    messages.value = { ...messages.value, [chatId]: list };
    streaming.value = { ...streaming.value, [chatId]: false };
    statuses.value = { ...statuses.value, [chatId]: { state, error, note } };
    lastSeq.delete(chatId);
  }

  function findPending(list: ChatMessageView[]): number {
    for (let i = list.length - 1; i >= 0; i--) {
      if (list[i].pending) return i;
    }
    return -1;
  }

  /** 拉取某本书的会话列表。 */
  async function loadChats(bookId: number): Promise<AIChatView[]> {
    if (!bookId) return [];
    // 绑定把无数据的 slice 标成可空，统一收敛成空数组，省得每处都判空。
    const list = (await aiApi.listChats(bookId)) ?? [];
    chats.value = { ...chats.value, [bookId]: list };
    return list;
  }

  /** 拉取某会话的消息。 */
  async function loadMessages(chatId: number): Promise<ChatMessageView[]> {
    if (!chatId) return [];
    const list = await aiApi.getMessages(chatId);
    const view: ChatMessageView[] = (list ?? []).map((m) => ({
      id: m.id,
      role: m.role,
      content: m.content,
      refs: (m.refs ?? []) as AIRefPayload[],
      pending: false,
    }));
    messages.value = { ...messages.value, [chatId]: view };
    return view;
  }

  /** 新建会话。 */
  async function createChat(bookId: number, title: string): Promise<AIChatView> {
    const chat = await aiApi.createChat(bookId, title);
    const list = chats.value[bookId] ?? [];
    chats.value = { ...chats.value, [bookId]: [chat, ...list] };
    messages.value = { ...messages.value, [chat.id]: [] };
    return chat;
  }

  async function removeChat(bookId: number, chatId: number) {
    await aiApi.deleteChat(chatId);
    const list = (chats.value[bookId] ?? []).filter((c) => c.id !== chatId);
    chats.value = { ...chats.value, [bookId]: list };
    const nextMessages = { ...messages.value };
    delete nextMessages[chatId];
    messages.value = nextMessages;
  }

  /** 提问。回答通过事件异步到达。 */
  async function ask(chatId: number, question: string) {
    const text = question.trim();
    if (!text) return;
    // 先本地插入提问，避免等一次往返才看到自己的话。
    const list = [...(messages.value[chatId] ?? [])];
    list.push({ id: -Date.now(), role: "user", content: text, refs: [], pending: false });
    messages.value = { ...messages.value, [chatId]: list };
    streaming.value = { ...streaming.value, [chatId]: true };
    statuses.value = { ...statuses.value, [chatId]: { state: "", error: "", note: "" } };
    lastSeq.delete(chatId);
    const before = list.length;
    try {
      await aiApi.ask(chatId, text);
    } catch (e) {
      // 提问没发出去：把刚插入的那条标记回可编辑状态，并如实报错。
      streaming.value = { ...streaming.value, [chatId]: false };
      statuses.value = {
        ...statuses.value,
        [chatId]: { state: "failed", error: (e as Error).message, note: "" },
      };
      throw e;
    }
    void watchAnswer(chatId, before);
  }

  /**
   * 事件丢失时的兜底：轮询后端，直到回答落库。
   *
   * 为什么需要：订阅依赖框架注入的运行时，注入时机不受应用控制（见 api/events.ts）。
   * 一旦订阅挂在收不到事件的注册表上，界面会永远停在「正在生成」，
   * 而回答其实早已写完入库。这条轮询保证最坏情况下也能在 2 秒内看到结果。
   */
  async function watchAnswer(chatId: number, before: number) {
    const deadline = Date.now() + 5 * 60 * 1000;
    while (Date.now() < deadline) {
      await sleep(2000);
      if (!isStreaming(chatId)) return;
      let list: Awaited<ReturnType<typeof aiApi.getMessages>> | null = null;
      try {
        list = await aiApi.getMessages(chatId);
      } catch {
        continue;
      }
      if (!list || list.length <= before) continue;
      const last = list[list.length - 1];
      if (!last || last.role !== "assistant") continue;
      // 后端已落库：以库里的内容收尾，事件丢了也不会卡住。
      applyDone(
        chatId,
        "done",
        last.content,
        (last.refs ?? []) as AIRefPayload[],
        "",
        "",
      );
      return;
    }
  }

  async function stop(chatId: number) {
    await aiApi.stopAnswer(chatId);
  }

  function messagesOf(chatId: number): ChatMessageView[] {
    return messages.value[chatId] ?? [];
  }

  function isStreaming(chatId: number): boolean {
    return streaming.value[chatId] === true;
  }

  function statusOf(chatId: number): AnswerStatus | null {
    return statuses.value[chatId] ?? null;
  }

  const runningIds = computed(() =>
    Object.entries(streaming.value)
      .filter(([, on]) => on)
      .map(([id]) => Number(id)),
  );

  return {
    chats,
    messages,
    streaming,
    runningIds,
    attach,
    detach,
    loadChats,
    loadMessages,
    createChat,
    removeChat,
    ask,
    stop,
    messagesOf,
    isStreaming,
    statusOf,
  };
});

/** 简易延时，仅用于轮询兜底。 */
function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
