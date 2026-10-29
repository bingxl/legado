/**
 * 后端事件订阅。
 *
 * 后端通过 port.EventBus 推送进度（导入、书源校验、WebDAV 同步）。
 * 事件名与 Go 侧 internal/port/event.go 中的常量保持一致，
 * 集中在此处定义，避免魔法字符串散落到各个页面。
 */
import { Events } from "@wailsio/runtime";

/** 后端事件名（对应 internal/port/event.go 中的常量）。 */
export const BackendEvents = {
  ImportProgress: "import:progress",
  SourceCheckProgress: "source:check:progress",
  DownloadProgress: "download:progress",
  WebDAVSyncProgress: "webdav:sync:progress",
} as const;

/** 进度类事件的载荷结构（导入 / 校验 / 同步共用）。 */
export interface ProgressPayload {
  total: number;
  done: number;
  current?: string;
  phase?: string;
  message?: string;
}

/** 订阅导入进度，返回取消订阅函数。 */
export function onImportProgress(handler: (data: ProgressPayload) => void) {
  return Events.On(BackendEvents.ImportProgress, (ev) =>
    handler(ev.data as ProgressPayload),
  );
}

/** 订阅书源校验进度。 */
export function onSourceCheckProgress(
  handler: (data: ProgressPayload) => void,
) {
  return Events.On(BackendEvents.SourceCheckProgress, (ev) =>
    handler(ev.data as ProgressPayload),
  );
}

/** 订阅 WebDAV 同步进度。 */
export function onWebDAVSyncProgress(handler: (data: ProgressPayload) => void) {
  return Events.On(BackendEvents.WebDAVSyncProgress, (ev) =>
    handler(ev.data as ProgressPayload),
  );
}
