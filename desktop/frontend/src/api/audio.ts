/**
 * 听书 API 防腐层（绑定服务 AudioAPI）。
 *
 * 与 reader.ts 同一套约定：只有本目录能引用 `@bindings`，对外用 camelCase，
 * 把生成物的返回类型收敛成前端自己的接口——生成物里 DTO 命名一变，只改这里。
 */
import * as binding from "@bindings/github.com/legado/desktop/api/audioapi";
import { call, callList } from "./client";

/** 一次解析出来的播放地址。 */
export interface ResolvedPlay {
  /**
   * 后端返回的 `/stream/<sid>.mp3` 代理地址。
   * 必须原样交给 `<audio src>`：不要自己拼前缀，也不要按字符串内容判断类型。
   * 前缀用 /stream/ 是为了避开播放页路由 /audio/:id，否则 F5 深链会被代理截走。
   */
  url: string;
  title: string;
  index: number;
}

/** 发起后台下载后立即返回的任务句柄。 */
export interface DownloadResult {
  bookId: number;
  total: number;
}

/** 已缓存的一章音频。 */
export interface CachedAudioItem {
  index: number;
  size: number;
  path: string;
}

/**
 * 听书服务态快照（对应 Go 侧 dto.AudioPlaybackState）。
 * 播放地址不在这里：/stream/ 会话是一次性的，不能进广播。
 */
export interface PlaybackStateSnapshot {
  bookId: number;
  bookName: string;
  chapterIndex: number;
  chapterTitle: string;
  cover: string;
  /** idle / loading / playing / paused / error */
  status: string;
  positionMs: number;
  durationMs: number;
  rate: number;
  playMode: string;
  /** 上报方标识；收到自己的回声要忽略。 */
  clientId: string;
  /** 服务端分配，上报时传 0。 */
  seq: number;
}

export const audioApi = {
  /**
   * 解析某章的可播放地址。
   *
   * 后端每次调用都会生成新 session、旧 session 立即失效，因此切章 / 循环 /
   * 换源都必须重新调用，不能缓存复用上一条 url。返回的 url 直接交给
   * HTMLAudioElement；后端已支持 Range/206，无需前端做任何流式处理。
   */
  resolvePlayURL: (bookId: number, index: number): Promise<ResolvedPlay> =>
    call(
      binding.ResolvePlayURL(bookId, index) as unknown as Promise<ResolvedPlay>,
    ),

  /** 后台下载一段章节；进度由 `audio:cache:progress` 事件推送。 */
  downloadAudio: (
    bookId: number,
    fromIndex: number,
    toIndex: number,
  ): Promise<DownloadResult> =>
    call(
      binding.DownloadAudio(
        bookId,
        fromIndex,
        toIndex,
      ) as unknown as Promise<DownloadResult>,
    ),

  /** 取消该书的下载任务。 */
  cancelDownload: (bookId: number) =>
    call(binding.CancelDownload(bookId)),

  /** 已缓存的音频章节清单。Go 的 nil slice 会序列化成 null，用 callList 收敛。 */
  cachedAudio: (bookId: number): Promise<CachedAudioItem[]> =>
    callList(
      binding.CachedAudio(
        bookId,
      ) as unknown as Promise<CachedAudioItem[] | null>,
    ),

  /** 删除指定章节的音频缓存。 */
  deleteAudioCache: (bookId: number, indexes: number[]) =>
    call(binding.DeleteAudioCache(bookId, indexes)),

  /**
   * 上报播放态。Go 侧补 seq 后广播 audio:playback:state，
   * 安卓宿主与其它窗口据此对齐；返回服务端确认的快照。
   */
  reportPlaybackState: (state: PlaybackStateSnapshot) =>
    call(
      binding.ReportPlaybackState(
        state as Parameters<typeof binding.ReportPlaybackState>[0],
      ) as unknown as Promise<PlaybackStateSnapshot>,
    ),

  /** 查询服务态快照（冷启动 / 宿主对齐用）。 */
  playbackState: () =>
    call(binding.PlaybackState() as unknown as Promise<PlaybackStateSnapshot>),
};
