/**
 * 单个 HTMLAudioElement 的封装，不依赖 Vue / Pinia。
 *
 * 只做一件事：把浏览器音频元素那堆事件与状态翻译成上层要的信号。
 * 关键在「切章 / 换源」竞态：每次 `load()` 都自增 generation 并重新挂一套
 * 监听器，旧 src 迟到的事件（切章时非常常见）一律丢弃，避免把上一章的
 * 时长 / 进度 / ended 写到新章上。
 */

export interface AudioEngineHandlers {
  onTimeUpdate?: (positionSec: number) => void;
  onDuration?: (durationSec: number) => void;
  onLoadedMetadata?: (durationSec: number) => void;
  onProgress?: (bufferedSec: number) => void;
  onEnded?: () => void;
  onError?: (message: string) => void;
  onWaiting?: () => void;
  onPlaying?: () => void;
}

/** MediaError.code 用数字比较，避免依赖各环境不一致的全局常量。 */
function describeError(err: MediaError | null): string {
  if (!err) return "音频加载失败（未知错误）";
  switch (err.code) {
    case 1: // MEDIA_ERR_ABORTED
      return "音频加载被中断";
    case 2: // MEDIA_ERR_NETWORK
      return "网络异常，音频加载失败（可能是 403 / 404 或跨域限制）";
    case 3: // MEDIA_ERR_DECODE
      return "音频解码失败：格式不支持或文件损坏";
    case 4: // MEDIA_ERR_SRC_NOT_SUPPORTED
      return "音频地址无效或格式不支持（可能是 403 / 404）";
    default:
      return `音频加载失败：${err.message || "未知错误"}`;
  }
}

export class AudioEngine {
  private readonly el: HTMLAudioElement;
  private handlers: AudioEngineHandlers;
  /** 每次 load / stop 自增；监听器据此判断自己是否已经过期。 */
  private generation = 0;
  private detach: Array<() => void> = [];

  constructor(handlers: AudioEngineHandlers = {}) {
    this.el = new Audio();
    this.el.preload = "auto";
    this.handlers = handlers;
  }

  setHandlers(handlers: AudioEngineHandlers): void {
    this.handlers = handlers;
  }

  /** 加载新的播放地址并切换监听器。 */
  load(url: string): void {
    const gen = ++this.generation;
    this.detachListeners();
    const alive = () => gen === this.generation;
    const listen = (name: string, fn: () => void) => {
      const wrapped = () => {
        if (alive()) fn();
      };
      this.el.addEventListener(name, wrapped);
      this.detach.push(() => this.el.removeEventListener(name, wrapped));
    };

    listen("timeupdate", () =>
      this.handlers.onTimeUpdate?.(this.el.currentTime),
    );
    listen("durationchange", () => this.handlers.onDuration?.(this.duration));
    listen("loadedmetadata", () =>
      this.handlers.onLoadedMetadata?.(this.duration),
    );
    listen("progress", () => this.handlers.onProgress?.(this.buffered));
    listen("ended", () => this.handlers.onEnded?.());
    listen("error", () =>
      this.handlers.onError?.(describeError(this.el.error)),
    );
    listen("waiting", () => this.handlers.onWaiting?.());
    listen("playing", () => this.handlers.onPlaying?.());

    this.el.src = url;
    this.el.load();
  }

  /** 返回浏览器 play() 的 promise，由上层决定如何处理自动播放策略拒绝。 */
  async play(): Promise<void> {
    await this.el.play();
  }

  pause(): void {
    this.el.pause();
  }

  /**
   * 停止并释放连接。
   * 清空 src 后再 load() 才能断开本地代理 session，否则后端会一直挂着旧流。
   */
  stop(): void {
    this.generation += 1;
    this.detachListeners();
    try {
      this.el.pause();
    } catch {
      /* 元素尚未就绪 */
    }
    try {
      this.el.removeAttribute("src");
      this.el.load();
    } catch {
      /* 同上 */
    }
  }

  /** 跳到指定秒数；超过总时长时夹到末尾。 */
  seek(sec: number): void {
    const d = this.duration;
    const target = Math.max(0, d > 0 ? Math.min(sec, d) : sec);
    try {
      this.el.currentTime = target;
    } catch {
      /* 元数据就绪前设置 currentTime 会抛错，忽略即可 */
    }
  }

  setRate(rate: number): void {
    this.el.playbackRate = Math.min(3, Math.max(0.5, rate));
  }

  setVolume(volume: number): void {
    this.el.volume = Math.min(1, Math.max(0, volume));
  }

  setMuted(muted: boolean): void {
    this.el.muted = muted;
  }

  get paused(): boolean {
    return this.el.paused;
  }

  private get duration(): number {
    const d = this.el.duration;
    return Number.isFinite(d) && d > 0 ? d : 0;
  }

  /** 已缓冲到的秒数：取最后一段缓冲区的末端。 */
  private get buffered(): number {
    const b = this.el.buffered;
    if (!b || b.length === 0) return 0;
    try {
      return b.end(b.length - 1);
    } catch {
      return 0;
    }
  }

  private detachListeners(): void {
    for (const off of this.detach) off();
    this.detach = [];
  }
}
