/** AI 总结与问答 API。 */
import * as binding from "@bindings/github.com/legado/desktop/api/aiapi";
import type { AIConfigInput } from "@bindings/github.com/legado/desktop/internal/app/dto/models";
import { call } from "./client";

export type {
  AIChatView,
  AIConfigView,
  AIIndexStatusView,
  AIMessageView,
  AIRefView,
  AISummaryView,
  AITestResult,
} from "@bindings/github.com/legado/desktop/internal/app/dto/models";

/**
 * 保存/测试连接的入参。apiKey 留空表示保持已存的密钥不变。
 *
 * 用 Partial 是因为调用方常只改其中几项；绑定的模型类型是 interface（纯类型，
 * 运行时不存在），因此直接传对象即可，缺省字段由 Go 端按零值处理。
 */
export type AIConfigForm = Partial<AIConfigInput>;

function toInput(form: AIConfigForm): AIConfigInput {
  return form as AIConfigInput;
}

/** 索引范围取值（与 Go 侧 domain.AIScope* 对应）。 */
export const AIScope = {
  All: "all",
  Read: "read",
  Range: "range",
} as const;

export type AIScopeValue = (typeof AIScope)[keyof typeof AIScope];

export const aiApi = {
  /** 读取配置（不含密钥明文，只给 hasKey 与掩码）。 */
  getConfig: () => call(binding.GetConfig()),

  /** 保存配置。 */
  saveConfig: (form: AIConfigForm) => call(binding.SaveConfig(toInput(form))),

  /** 用当前表单值试探连通性，无需先保存。 */
  testConnection: (form: AIConfigForm) =>
    call(binding.TestConnection(toInput(form))),

  /**
   * 启动索引。方法立即返回，进度靠 ai:index:progress 事件推送。
   *
   * 整本索引可能几十分钟且要花钱，所以同步等待不可行——前端拿不到取消机会。
   */
  startIndex: (
    bookId: number,
    scope: AIScopeValue,
    from = 0,
    to = 0,
  ) => call(binding.StartIndex(bookId, scope, from, to)),

  /** 取消正在进行的索引。 */
  cancelIndex: (bookId: number) => call(binding.CancelIndex(bookId)),

  /** 查询索引状态。 */
  indexStatus: (bookId: number) => call(binding.IndexStatus(bookId)),

  /** 删除该书的全部索引数据。 */
  deleteIndex: (bookId: number) => call(binding.DeleteIndex(bookId)),

  /** 读取已生成的全书摘要。 */
  getSummary: (bookId: number) => call(binding.GetSummary(bookId)),

  /** 对指定章节区间生成摘要，不建立完整索引（便宜、只读一次）。 */
  summarizeChapters: (bookId: number, from: number, to: number) =>
    call(binding.SummarizeChapters(bookId, from, to)),

  // ── 会话 ────────────────────────────────────────────────
  createChat: (bookId: number, title: string) =>
    call(binding.CreateChat(bookId, title)),
  listChats: (bookId: number) => call(binding.ListChats(bookId)),
  getMessages: (chatId: number) => call(binding.GetMessages(chatId)),
  deleteChat: (chatId: number) => call(binding.DeleteChat(chatId)),

  /**
   * 提问。方法立即返回，回答通过事件到达：
   * ai:answer:chunk 逐段、ai:answer:done 结束（带完整正文与引用）。
   */
  ask: (chatId: number, question: string) => call(binding.Ask(chatId, question)),
  stopAnswer: (chatId: number) => call(binding.StopAnswer(chatId)),
};
