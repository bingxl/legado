/**
 * 听书（音频书源）相关的本地领域类型。
 *
 * bindings 已生成，DTO 里 `isAudio / type / duration` 等字段都真实存在；
 * 这里保留一组结构兼容的本地接口与 `as unknown as AudioBookLike` 读取方式，
 * 是为了让后端统一简化类型时只改一处（见 fe-audio 与 team-lead 的约定）。
 * 字段名与真实 DTO 对齐：封面是 `cover`，不是 `coverUrl`。
 */

/** 后端书籍对象里，听书页需要读到的字段。 */
export interface AudioBookLike {
  id: number;
  name: string;
  author?: string;
  /** 真实 DTO 字段名为 cover；store 内部另用 coverUrl 存同一份地址。 */
  cover?: string;
  origin?: string;
  isAudio?: boolean;
  /** Legado Book.type 位域，音频为 32。 */
  type?: number;
  totalChapters?: number;
  durChapterIndex?: number;
  /** 毫秒；进入播放页时据此恢复进度。 */
  durChapterPos?: number;
}

/** 目录条目里，听书页需要读到的字段。 */
export interface AudioChapterLike {
  index: number;
  title: string;
  /** 音频章节时长，单位毫秒。 */
  duration?: number;
}

/** 播放模式：对齐 Kotlin 原版 AudioPlay 的四态。 */
export type PlayMode =
  | "LIST_END_STOP"
  | "SINGLE_LOOP"
  | "RANDOM"
  | "LIST_LOOP";

/** 播放状态。 */
export type AudioStatus = "idle" | "loading" | "playing" | "paused" | "error";

/**
 * 是否音频书。
 *
 * 新 DTO 直接给 `isAudio`；老数据用 `Book.type` 位域兜底
 * （Kotlin 原版：音频书源 type=1 会落到 Book.type 的 32 位）。四个入口（书架、
 * 详情、搜索、发现）共用这一处判定，避免各自把位域写错。
 */
export function isAudioBook(x: unknown): boolean {
  if (!x || typeof x !== "object") return false;
  const o = x as AudioBookLike;
  if (o.isAudio === true) return true;
  return typeof o.type === "number" && (o.type & 32) !== 0;
}
