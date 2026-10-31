/**
 * 后端事件订阅。
 *
 * 后端通过 port.EventBus 推送进度（导入、书源校验、缓存、WebDAV 同步）。
 * 事件名与 Go 侧 internal/port/event.go 中的常量保持一致，
 * 集中在此处定义，避免魔法字符串散落到各个页面。
 *
 * 订阅必须走 `window.wails`（框架注入的运行时），而不是 import 进来的 Events：
 * `@wailsio/runtime` 被一起打包进产物后自带一份事件注册表与分发函数，
 * 而真正接收后端事件的是注入的运行时——两份注册表互不相通。直接用打包副本
 * 订阅时，开发模式下看似正常，生产构建里一个事件都收不到（缓存进度条
 * 不上报就是这么被发现的）。全局运行时不存在时才退回打包副本（单测环境）。
 */
import { Events } from "@wailsio/runtime";

/** 后端事件名（对应 internal/port/event.go 中的常量）。 */
export const BackendEvents = {
  ImportProgress: "import:progress",
  SourceCheckProgress: "source:check:progress",
  SourceDebug: "source:debug",
  SourceDebugDone: "source:debug:done",
  DownloadProgress: "download:progress",
  CacheProgress: "cache:progress",
  WebDAVSyncProgress: "webdav:sync:progress",
  WebDAVImportProgress: "webdav:import:progress",
  AIIndexProgress: "ai:index:progress",
  AIAnswerChunk: "ai:answer:chunk",
  AIAnswerDone: "ai:answer:done",
} as const;

/** 章节缓存进度载荷（对应 Go 侧 dto.CacheProgress）。 */
export interface CacheProgressPayload {
  bookId: number;
  bookName: string;
  state: string;
  total: number;
  done: number;
  failed: number;
  current: string;
  message: string;
}

/** AI 索引进度（对应 Go 侧 dto.AIIndexProgress）。 */
export interface AIIndexProgressPayload {
  bookId: number;
  /** fetch / chunk / embed / summary / done / failed / canceled */
  phase: string;
  done: number;
  total: number;
  message: string;
  /** 后端进程内单调递增的序号，用于丢弃迟到的事件（乱序到达很常见）。 */
  seq: number;
}

/** AI 回答的流式分片（对应 Go 侧 dto.AIAnswerChunk）。 */
export interface AIAnswerChunkPayload {
  chatId: number;
  bookId: number;
  delta: string;
  /** 从 1 起严格递增，用于丢弃重复或乱序分片。 */
  seq: number;
}

/** AI 回答结束（对应 Go 侧 dto.AIAnswerDone）。 */
export interface AIAnswerDonePayload {
  chatId: number;
  bookId: number;
  /** done / canceled / failed */
  state: string;
  content: string;
  refs: AIRefPayload[];
  error: string;
  /** 降级说明，例如「未配置向量模型，正在用关键词匹配」。 */
  note: string;
}

/** 回答引用的一条出处（对应 Go 侧 dto.AIRefView）。 */
export interface AIRefPayload {
  chunkId: number;
  chapterIdx: number;
  title: string;
  score: number;
  excerpt: string;
}

/** 书源调试打点（对应 Go 侧 dto.DebugEntryView）。 */export interface SourceDebugEntryPayload {
  session: string;
  elapsedMs: number;
  state: number;
  /** log / error / list / info / toc / content / done */
  stateName: string;
  msg: string;
}

/** 书源调试结束（对应 Go 侧 dto.DebugDoneView）。 */
export interface SourceDebugDonePayload {
  session: string;
  failed: boolean;
  reason: string;
  elapsedMs: number;
}

/** WebDAV 选书导入进度（对应 Go 侧 dto.WebDAVImportProgress）。 */
export interface WebDAVImportProgressPayload {
  state: string;
  /** scan / download / import / done / error */
  phase: string;
  total: number;
  done: number;
  failed: number;
  current: string;
  bytes: number;
  totalBytes: number;
  message: string;
}

/** 进度类事件的载荷结构（导入 / 校验 / 同步共用）。 */
export interface ProgressPayload {
  total: number;
  done: number;
  current?: string;
  phase?: string;
  message?: string;
}

/** 全局运行时暴露的事件接口（只用到 On）。 */
interface WailsEventsApi {
  On(name: string, callback: (event: { data: unknown }) => void): () => void;
}

/** 取出真正在接收后端事件的运行时；取不到返回 null。 */
function eventsApi(): WailsEventsApi | null {
  const wails = (window as unknown as { wails?: { Events?: WailsEventsApi } })
    .wails;
  return wails?.Events ?? null;
}

/** 等待全局运行时注入的轮询间隔与上限。 */
const RUNTIME_POLL_MS = 100;
/** 最长等待时长。超时后仍会继续用打包副本兜底，但不再轮询。 */
const RUNTIME_WAIT_MS = 60000;

/**
 * 订阅后端事件，返回取消订阅函数。
 *
 * 首屏挂载时 `window.wails` 可能还没注入（框架的 runtime 脚本比应用脚本晚到），
 * 此时若直接退回打包副本，注册的就是那份收不到事件的注册表 —— 表现为
 * 「界面一切正常但进度条永远不出现」。
 *
 * 因此这里做两件事：先挂到打包副本兜底（至少同页内的逻辑还能跑通），
 * 同时持续等待真身注入；一旦 `window.wails.Events` 出现，就把订阅迁移过去。
 * 早先的实现只等 5 秒就放弃，冷启动稍慢的机器上会永久收不到任何后端事件
 * （AI 流式回答一个字都不显示，就是这么暴露出来的）。
 */
function subscribe<T>(name: string, handler: (data: T) => void): () => void {
  let stopped = false;
  let boundToLive = false;
  let unsubscribe: (() => void) | null = null;

  const bind = (api: WailsEventsApi) => {
    unsubscribe?.();
    unsubscribe = api.On(name, (ev) => handler(ev.data as T));
  };

  const live = eventsApi();
  if (live) {
    bind(live);
    boundToLive = true;
  } else {
    // 兜底订阅：打包副本的注册表与后端不互通，但保留它可以让
    // 同一页面内的自触发逻辑（测试、调试）仍然工作。
    unsubscribe = Events.On(name, (ev) => handler((ev as { data: T }).data));
  }

  let waited = 0;
  const timer = setInterval(() => {
    waited += RUNTIME_POLL_MS;
    if (stopped || boundToLive || waited > RUNTIME_WAIT_MS) {
      clearInterval(timer);
      return;
    }
    const now = eventsApi();
    if (!now) return;
    bind(now);
    boundToLive = true;
    clearInterval(timer);
  }, RUNTIME_POLL_MS);

  return () => {
    stopped = true;
    clearInterval(timer);
    unsubscribe?.();
  };
}

/** 订阅导入进度，返回取消订阅函数。 */
export function onImportProgress(handler: (data: ProgressPayload) => void) {
  return subscribe(BackendEvents.ImportProgress, handler);
}

/** 订阅书源校验进度。 */
export function onSourceCheckProgress(
  handler: (data: ProgressPayload) => void,
) {
  return subscribe(BackendEvents.SourceCheckProgress, handler);
}

/** 订阅章节缓存进度。 */
export function onCacheProgress(handler: (data: CacheProgressPayload) => void) {
  return subscribe(BackendEvents.CacheProgress, handler);
}

/** 订阅 AI 索引进度。 */
export function onAIIndexProgress(
  handler: (data: AIIndexProgressPayload) => void,
) {
  return subscribe(BackendEvents.AIIndexProgress, handler);
}

/** 订阅 AI 回答的流式分片。 */
export function onAIAnswerChunk(
  handler: (data: AIAnswerChunkPayload) => void,
) {
  return subscribe(BackendEvents.AIAnswerChunk, handler);
}

/** 订阅 AI 回答结束。 */
export function onAIAnswerDone(handler: (data: AIAnswerDonePayload) => void) {
  return subscribe(BackendEvents.AIAnswerDone, handler);
}

/** 订阅 WebDAV 同步进度。 */
export function onWebDAVSyncProgress(handler: (data: ProgressPayload) => void) {
  return subscribe(BackendEvents.WebDAVSyncProgress, handler);
}

/** 订阅「从 WebDAV 导入书籍」的进度。 */
export function onWebDAVImportProgress(
  handler: (data: WebDAVImportProgressPayload) => void,
) {
  return subscribe(BackendEvents.WebDAVImportProgress, handler);
}

/** 订阅书源调试打点（每条一行）。 */
export function onSourceDebug(
  handler: (data: SourceDebugEntryPayload) => void,
) {
  return subscribe(BackendEvents.SourceDebug, handler);
}

/** 订阅书源调试结束。 */
export function onSourceDebugDone(
  handler: (data: SourceDebugDonePayload) => void,
) {
  return subscribe(BackendEvents.SourceDebugDone, handler);
}
