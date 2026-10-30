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

/** 书源调试打点（对应 Go 侧 dto.DebugEntryView）。 */
export interface SourceDebugEntryPayload {
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
const RUNTIME_WAIT_MS = 5000;

/**
 * 订阅后端事件，返回取消订阅函数。
 *
 * 首屏挂载时 `window.wails` 可能还没注入（框架的 runtime 脚本比应用脚本晚到），
 * 此时若直接退回打包副本，注册的就是那份收不到事件的注册表 —— 表现为
 * 「界面一切正常但进度条永远不出现」。所以先等一会儿，超时才退回副本。
 */
function subscribe<T>(name: string, handler: (data: T) => void): () => void {
  const api = eventsApi();
  if (api) return api.On(name, (ev) => handler(ev.data as T));

  let stopped = false;
  let unsubscribe: (() => void) | null = null;
  let waited = 0;

  const timer = setInterval(() => {
    waited += RUNTIME_POLL_MS;
    const live = eventsApi();
    if (!live && waited < RUNTIME_WAIT_MS) return;
    clearInterval(timer);
    if (stopped) return;
    unsubscribe = live
      ? live.On(name, (ev) => handler(ev.data as T))
      : Events.On(name, (ev) => handler((ev as { data: T }).data));
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
