/**
 * 听书播放状态机：全局唯一的播放状态源（对齐 Kotlin 原版 AudioPlay object）。
 *
 * 状态与音频元素都放在 store 里，播放条挂在 App 外壳而非某个页面，
 * 因此离开播放页后仍继续播放、仍能控制。所有「换章」都走 loadChapter：
 * 它自增 generation、重新 resolve 播放地址、再换掉 AudioEngine 的 src，
 * 旧章迟到的回调一律丢弃。
 */
import { defineStore } from "pinia";
import { computed, ref, watch } from "vue";

import { audioApi } from "@/api/audio";
import type { PlaybackStateSnapshot } from "@/api/audio";
import { readerApi } from "@/api/reader";
import {
  onAudioCacheProgress,
  onAudioCommand,
  onAudioPlaybackState,
} from "@/api/events";
import type {
  AudioCacheProgressPayload,
  AudioCommandPayload,
  AudioPlaybackStatePayload,
} from "@/api/events";
import { AudioEngine } from "@/audio/AudioEngine";
import { loadAudioPrefs, saveAudioPrefs } from "@/audio/prefs";
import { useTtsStore } from "@/stores/tts";
import { coverURL } from "@/utils/media";
import type { AudioStatus, PlayMode } from "@/types/audio";

export interface AudioStartOptions {
  bookId: number;
  bookName: string;
  /** 封面地址，取自 DTO 的 `cover` 字段（store 内部统一叫 coverUrl）。 */
  coverUrl?: string;
  origin?: string;
  index: number;
  /** 毫秒；进入播放页时据此恢复进度。 */
  positionMs: number;
}

/** 后台下载任务的轻量视图。 */
export interface AudioDownloadState {
  state: string;
  done: number;
  total: number;
  error: string;
}

const PLAY_MODES: PlayMode[] = [
  "LIST_END_STOP",
  "SINGLE_LOOP",
  "RANDOM",
  "LIST_LOOP",
];
/** 进度自动落盘节流：播放中每秒最多写一次，拖动中每一帧都写库没有意义。 */
const SAVE_THROTTLE_MS = 1000;
/** 播放态广播节流：timeupdate 每秒数次，状态/章节变化则强制立即上报。 */
const STATE_THROTTLE_MS = 1000;
/** 本页标识：Go 广播会原样带回，前端据此忽略自己的回声。 */
const CLIENT_ID = `webview-${Math.random().toString(36).slice(2)}`;
const MEDIA_ACTIONS = [
  "play",
  "pause",
  "previoustrack",
  "nexttrack",
  "seekto",
  "seekbackward",
  "seekforward",
];

export const useAudioPlayerStore = defineStore("audioPlayer", () => {
  const prefs = loadAudioPrefs();

  // ── 书籍与章节 ────────────────────────────────────────────
  const bookId = ref(0);
  const bookName = ref("");
  const coverUrl = ref("");
  const origin = ref("");
  const chapterIndex = ref(0);
  const chapterTitle = ref("");
  const playUrl = ref("");
  const totalChapters = ref(0);
  const cachedIndexes = ref<number[]>([]);

  // ── 播放状态 ──────────────────────────────────────────────
  const status = ref<AudioStatus>("idle");
  const errorMsg = ref("");
  const positionMs = ref(0);
  const durationMs = ref(0);
  const bufferedMs = ref(0);
  const rate = ref(prefs.rate);
  const volume = ref(prefs.volume);
  const muted = ref(false);
  const playMode = ref<PlayMode>(prefs.playMode);
  const autoNext = ref(prefs.autoNext);
  const timerMinutes = ref(prefs.timerMinutes);
  const timerRemainSec = ref(0);
  const download = ref<AudioDownloadState>({
    state: "idle",
    done: 0,
    total: 0,
    error: "",
  });

  const isActive = computed(() => status.value !== "idle");
  const progressPct = computed(() =>
    durationMs.value > 0
      ? Math.min(100, (positionMs.value / durationMs.value) * 100)
      : 0,
  );
  const bufferedPct = computed(() =>
    durationMs.value > 0
      ? Math.min(100, (bufferedMs.value / durationMs.value) * 100)
      : 0,
  );

  // ── 内部状态 ──────────────────────────────────────────────
  let loadGen = 0;
  let pendingSeekMs = 0;
  let lastSaveAt = 0;
  let lastStateAt = 0;
  let lastSeenSeq = 0;
  let timerId: ReturnType<typeof setInterval> | null = null;

  const engine = new AudioEngine({
    onTimeUpdate: (sec) => {
      positionMs.value = Math.round(sec * 1000);
      saveProgress();
      publishState();
    },
    onDuration: (sec) => {
      if (sec > 0) {
        durationMs.value = Math.round(sec * 1000);
        publishState();
      }
    },
    onLoadedMetadata: (sec) => {
      if (sec > 0) durationMs.value = Math.round(sec * 1000);
      // 元数据就绪后才能 seek；进度 restoration 落在这里。
      if (pendingSeekMs > 0) {
        engine.seek(pendingSeekMs / 1000);
        positionMs.value = pendingSeekMs;
        pendingSeekMs = 0;
      }
    },
    onProgress: (sec) => {
      bufferedMs.value = Math.round(sec * 1000);
    },
    onEnded: () => onEnded(),
    onError: (msg) => {
      status.value = "error";
      errorMsg.value = msg;
    },
    onWaiting: () => {
      if (status.value === "playing") status.value = "loading";
    },
    onPlaying: () => {
      status.value = "playing";
    },
  });

  // chapterIndex 变化时刷新系统媒体信息；状态变化时同步播放态。
  watch(chapterIndex, () => updateMediaSession());
  watch(status, (s) => setPlaybackState(s));
  // 离散状态变化立即广播；连续的进度走 publishState() 的一秒节流。
  watch(
    [status, chapterIndex, chapterTitle, bookName, rate, playMode],
    () => publishState(true),
  );

  // 后台下载进度：订阅放在 store 里，切页面也不丢。
  onAudioCacheProgress((p: AudioCacheProgressPayload) => {
    if (p.bookId !== bookId.value) return;
    download.value = {
      state: p.state,
      done: p.done,
      total: p.total,
      error: p.error ?? "",
    };
    if (p.state === "done" || p.state === "canceled" || p.state === "error") {
      void refreshCached();
    }
  });

  // ── 服务态 / 原生控制 ─────────────────────────────────────

  /**
   * 安卓宿主在 window.wails 上注入的播放态出口。
   * 桌面端没有这个接口 → 返回 null，所有原生相关逻辑自动降级为纯前端方案。
   * 用能力探测而不是平台判定：?ui=mobile 只是覆盖外壳，不会凭空造出宿主。
   */
  function nativeAudio(): { audioState: (json: string) => void } | null {
    try {
      const w = (
        window as unknown as {
          wails?: { audioState?: unknown };
        }
      ).wails;
      return typeof w?.audioState === "function"
        ? (w as unknown as { audioState: (json: string) => void })
        : null;
    } catch {
      return null;
    }
  }

  /** 组装一份不含播放地址的服务态快照。 */
  function snapshot(): PlaybackStateSnapshot {
    return {
      bookId: bookId.value,
      bookName: bookName.value,
      chapterIndex: chapterIndex.value,
      chapterTitle: chapterTitle.value,
      cover: coverUrl.value,
      status: status.value,
      positionMs: positionMs.value,
      durationMs: durationMs.value,
      rate: rate.value,
      playMode: playMode.value,
      clientId: CLIENT_ID,
      seq: 0,
    };
  }

  /**
   * 把播放态同时推给 Go（广播 audio:playback:state）和安卓前台 Service
   * （更新通知栏 / MediaSession / 音频焦点 / WakeLock）。
   * 两条通道互不依赖：桌面端 Go 广播照常工作，Go 侧事件总线故障也不影响播放。
   */
  function publishState(force = false): void {
    const now = Date.now();
    if (!force && now - lastStateAt < STATE_THROTTLE_MS) return;
    lastStateAt = now;
    const st = snapshot();
    void audioApi
      .reportPlaybackState(st)
      .then((ack) => {
        if (ack?.seq > lastSeenSeq) lastSeenSeq = ack.seq;
      })
      .catch(() => {});
    try {
      nativeAudio()?.audioState(JSON.stringify(st));
    } catch {
      // 宿主不存在或已销毁：不影响播放
    }
  }

  /** 原生媒体键 / 通知栏 / 音频焦点 / 拔耳机指令。 */
  onAudioCommand((cmd: AudioCommandPayload) => {
    switch (cmd.action) {
      case "play":
        void play();
        break;
      case "pause":
        pause();
        break;
      case "toggle":
        toggle();
        break;
      case "prev":
        prev();
        break;
      case "next":
        next();
        break;
      case "stop":
        stop();
        break;
      case "seekto":
        if (typeof cmd.value === "number") seekMs(cmd.value);
        break;
      case "seekbackward":
      case "seekforward": {
        const sec = typeof cmd.value === "number" ? cmd.value : 15;
        nudge(cmd.action === "seekbackward" ? -Math.abs(sec) : Math.abs(sec));
        break;
      }
      case "duck":
        // 短暂丢失焦点时系统会自动 duck，这里只把状态标记出来，不改用户音量偏好。
        break;
      default:
        break;
    }
  });

  /**
   * Go 广播的服务态：忽略自己的回声，只处理其它控制器发来的、序号更新的事件。
   * 目前只对外部的「已停止」生效——避免另一个窗口的进度把本地播放来回拽。
   */
  onAudioPlaybackState((st: AudioPlaybackStatePayload) => {
    if (!st || st.clientId === CLIENT_ID || st.seq <= lastSeenSeq) return;
    lastSeenSeq = st.seq;
    if (st.status === "idle" && isActive.value) stop();
  });

  // ── MediaSession ──────────────────────────────────────────

  function mediaSession(): any {
    try {
      return (navigator as any)?.mediaSession ?? null;
    } catch {
      return null;
    }
  }

  function updateMediaSession(): void {
    // 真安卓由宿主 MediaSession 独占系统媒体控制，避免 WebView 与原生各注册一份。
    if (nativeAudio()) return;
    try {
      const ms = mediaSession();
      if (!ms) return;
      const MM = (window as any).MediaMetadata;
      if (MM) {
        const art = coverUrl.value ? coverURL(coverUrl.value) : "";
        ms.metadata = new MM({
          title: chapterTitle.value || bookName.value,
          artist: bookName.value,
          album: bookName.value,
          artwork: art
            ? [{ src: art, sizes: "512x512", type: "image/jpeg" }]
            : [],
        });
      }
      setPlaybackState();
    } catch {
      // MediaSession 不可用不影响播放
    }
  }

  function setMediaHandlers(): void {
    // 真安卓上由宿主 AudioPlayService 的 MediaSession 独占系统媒体键，
    // 指令经 audio:command 回来；两套 MediaSession 同时激活会抢按键。
    if (nativeAudio()) return;
    try {
      const ms = mediaSession();
      if (!ms?.setActionHandler) return;
      const bind = (action: string, fn: (d?: any) => void) => {
        try {
          ms.setActionHandler(action, fn);
        } catch {
          // 部分 action 在当前平台不被支持
        }
      };
      bind("play", () => void play());
      bind("pause", () => pause());
      bind("previoustrack", () => void prev());
      bind("nexttrack", () => void next());
      bind("seekto", (d) => {
        if (d && typeof d.seekTime === "number") seekMs(d.seekTime * 1000);
      });
      bind("seekbackward", (d) => nudge(-(d?.seekOffset ?? 15)));
      bind("seekforward", (d) => nudge(d?.seekOffset ?? 15));
    } catch {
      // 忽略
    }
  }

  function clearMediaSession(): void {
    if (nativeAudio()) return;
    try {
      const ms = mediaSession();
      if (!ms) return;
      ms.metadata = null;
      ms.playbackState = "none";
      for (const a of MEDIA_ACTIONS) {
        try {
          ms.setActionHandler(a, null);
        } catch {
          // 忽略
        }
      }
    } catch {
      // 忽略
    }
  }

  function setPlaybackState(s: AudioStatus = status.value): void {
    if (nativeAudio()) return;
    try {
      const ms = mediaSession();
      if (!ms) return;
      ms.playbackState =
        s === "playing" ? "playing" : s === "idle" ? "none" : "paused";
    } catch {
      // 忽略
    }
  }

  // ── 播放控制 ──────────────────────────────────────────────

  async function start(opts: AudioStartOptions): Promise<void> {
    // 与 TTS 互斥：同一时间只允许一个发声源。
    try {
      const tts = useTtsStore();
      if (tts.isActive) tts.stop();
    } catch {
      // 忽略
    }

    bookId.value = opts.bookId;
    bookName.value = opts.bookName;
    coverUrl.value = opts.coverUrl ?? "";
    origin.value = opts.origin ?? "";
    chapterIndex.value = opts.index;
    chapterTitle.value = "";
    playUrl.value = "";
    errorMsg.value = "";
    positionMs.value = opts.positionMs;
    durationMs.value = 0;
    bufferedMs.value = 0;
    status.value = "loading";

    setMediaHandlers();
    updateMediaSession();
    // 默认定时：进播放页就按偏好起表（0 表示不启用）。
    if (timerMinutes.value > 0) setTimer(timerMinutes.value);
    void refreshCached();

    await loadChapter(opts.index, opts.positionMs);
  }

  /** 换章：重新 resolve（旧 session 失效）→ 换 src → 播放。 */
  async function loadChapter(index: number, startMs: number): Promise<void> {
    if (!bookId.value) return;
    const gen = ++loadGen;
    status.value = "loading";
    errorMsg.value = "";
    chapterIndex.value = index;
    chapterTitle.value = `第 ${index + 1} 章`;
    playUrl.value = "";
    positionMs.value = startMs;
    durationMs.value = 0;
    bufferedMs.value = 0;
    // 换章一律从 0 开始；只有「进入时恢复进度」才带非零值。
    pendingSeekMs = startMs;
    try {
      const res = await audioApi.resolvePlayURL(bookId.value, index);
      if (gen !== loadGen) return; // 旧章的 resolve 迟到，丢弃
      chapterTitle.value = res.title || `第 ${index + 1} 章`;
      // res.url 是后端 /stream/<sid>.mp3 代理地址，原样交给引擎，不拼前缀、不判断内容。
      playUrl.value = res.url;
      engine.load(res.url);
      engine.setRate(rate.value);
      engine.setVolume(volume.value);
      engine.setMuted(muted.value);
      updateMediaSession();
      await play();
    } catch (e) {
      if (gen !== loadGen) return;
      status.value = "error";
      errorMsg.value = (e as Error).message || "音频加载失败";
    }
  }

  async function play(): Promise<void> {
    if (!bookId.value) return;
    if (status.value === "error") {
      void loadChapter(chapterIndex.value, positionMs.value);
      return;
    }
    try {
      await engine.play();
      status.value = "playing";
    } catch (e) {
      const err = e as Error;
      // AbortError 是换章打断了上一次 play()，NotAllowedError 是自动播放策略，
      // 都不是故障，别把界面推到 error。
      if (err.name === "AbortError") return;
      if (err.name === "NotAllowedError") {
        status.value = "paused";
        return;
      }
      status.value = "error";
      errorMsg.value = err.message || "播放失败";
    }
  }

  function pause(): void {
    if (status.value === "idle") return;
    engine.pause();
    status.value = "paused";
    saveProgress(true);
  }

  function toggle(): void {
    if (status.value === "playing" || status.value === "loading") pause();
    else void play();
  }

  function stop(): void {
    saveProgress(true);
    engine.stop();
    loadGen += 1; // 丢弃在途的 resolve
    clearTimer();
    clearMediaSession();
    status.value = "idle";
    errorMsg.value = "";
    bookId.value = 0;
    bookName.value = "";
    coverUrl.value = "";
    origin.value = "";
    chapterTitle.value = "";
    playUrl.value = "";
    positionMs.value = 0;
    durationMs.value = 0;
    bufferedMs.value = 0;
    pendingSeekMs = 0;
    timerRemainSec.value = 0;
    cachedIndexes.value = [];
    download.value = { state: "idle", done: 0, total: 0, error: "" };
  }

  function next(): void {
    void loadChapter(clampIndex(chapterIndex.value + 1), 0);
  }

  function prev(): void {
    void loadChapter(clampIndex(chapterIndex.value - 1), 0);
  }

  function jumpTo(index: number): void {
    void loadChapter(clampIndex(index), 0);
  }

  function seekMs(ms: number): void {
    const max = durationMs.value > 0 ? durationMs.value : Number.MAX_SAFE_INTEGER;
    const clamped = Math.max(0, Math.min(Math.round(ms), max));
    positionMs.value = clamped;
    pendingSeekMs = 0;
    engine.seek(clamped / 1000);
    saveProgress(true);
  }

  function nudge(sec: number): void {
    seekMs(positionMs.value + sec * 1000);
  }

  /** 章末：按播放模式决定下一动作。 */
  function onEnded(): void {
    if (playMode.value === "SINGLE_LOOP") {
      void loadChapter(chapterIndex.value, 0);
      return;
    }
    if (!autoNext.value) {
      pause();
      return;
    }
    switch (playMode.value) {
      case "LIST_END_STOP": {
        // 列表结束停止：中间章节顺序续播，到最后一章停下。
        if (
          totalChapters.value > 0 &&
          chapterIndex.value + 1 >= totalChapters.value
        ) {
          pause();
          return;
        }
        void loadChapter(chapterIndex.value + 1, 0);
        return;
      }
      case "RANDOM":
        void loadChapter(randomIndex(), 0);
        return;
      case "LIST_LOOP": {
        const nextIdx =
          totalChapters.value > 0
            ? (chapterIndex.value + 1) % totalChapters.value
            : chapterIndex.value + 1;
        void loadChapter(nextIdx, 0);
        return;
      }
    }
  }

  function randomIndex(): number {
    if (totalChapters.value <= 1) return 0;
    let i = chapterIndex.value;
    // 尽量别挑到当前章，避免「随机」听感上没换。
    while (i === chapterIndex.value) {
      i = Math.floor(Math.random() * totalChapters.value);
    }
    return i;
  }

  function clampIndex(i: number): number {
    const max =
      totalChapters.value > 0 ? totalChapters.value - 1 : Number.MAX_SAFE_INTEGER;
    return Math.max(0, Math.min(i, max));
  }

  // ── 参数 ──────────────────────────────────────────────────

  function setRate(r: number): void {
    rate.value = Math.round(Math.min(3, Math.max(0.5, r)) * 10) / 10;
    engine.setRate(rate.value);
    saveAudioPrefs({ rate: rate.value });
  }

  function setVolume(v: number): void {
    volume.value = Math.min(1, Math.max(0, v));
    engine.setVolume(volume.value);
    saveAudioPrefs({ volume: volume.value });
  }

  function setMuted(m: boolean): void {
    muted.value = m;
    engine.setMuted(m);
  }

  function setAutoNext(on: boolean): void {
    autoNext.value = on;
    saveAudioPrefs({ autoNext: on });
  }

  function cyclePlayMode(): void {
    const i = PLAY_MODES.indexOf(playMode.value);
    playMode.value = PLAY_MODES[(i + 1) % PLAY_MODES.length];
    saveAudioPrefs({ playMode: playMode.value });
  }

  function setTotalChapters(n: number): void {
    totalChapters.value = Math.max(0, Math.trunc(n) || 0);
  }

  // ── 定时停止 ──────────────────────────────────────────────

  /** 只改「默认定时」偏好，不起表；供设置页调用。 */
  function setTimerMinutes(minutes: number): void {
    const m = Math.max(0, Math.min(180, Math.round(minutes)));
    timerMinutes.value = m;
    saveAudioPrefs({ timerMinutes: m });
  }

  /** 起表：每秒递减，到 0 自动 pause 并清零。 */
  function setTimer(minutes: number): void {
    setTimerMinutes(minutes);
    clearTimer();
    if (timerMinutes.value <= 0) {
      timerRemainSec.value = 0;
      return;
    }
    timerRemainSec.value = timerMinutes.value * 60;
    timerId = setInterval(() => {
      if (timerRemainSec.value <= 1) {
        clearTimer();
        timerRemainSec.value = 0;
        pause();
      } else {
        timerRemainSec.value -= 1;
      }
    }, 1000);
  }

  function addTimer(minutes: number): void {
    const base =
      timerRemainSec.value > 0
        ? Math.ceil(timerRemainSec.value / 60)
        : timerMinutes.value;
    setTimer(base + minutes);
  }

  function clearTimer(): void {
    if (timerId !== null) {
      clearInterval(timerId);
      timerId = null;
    }
  }

  // ── 进度回写 ──────────────────────────────────────────────

  /**
   * 复用阅读器进度接口：音频书里 chapterPos 就是播放毫秒，scrollPercent 固定传 0。
   * 自动回写只在播放时进行并节流 1s；暂停 / 停止 / 拖动结束强制落一次盘。
   */
  function saveProgress(force = false): void {
    if (!bookId.value || status.value === "idle") return;
    if (!force && status.value !== "playing") return;
    const now = Date.now();
    if (!force && now - lastSaveAt < SAVE_THROTTLE_MS) return;
    lastSaveAt = now;
    void readerApi
      .saveProgress(
        bookId.value,
        chapterIndex.value,
        chapterTitle.value,
        Math.round(positionMs.value),
        0,
      )
      .catch(() => {});
  }

  // ── 缓存 / 下载 ───────────────────────────────────────────

  async function downloadRange(
    bookIdArg: number,
    from: number,
    to: number,
  ): Promise<void> {
    try {
      const res = await audioApi.downloadAudio(bookIdArg, from, to);
      download.value = {
        state: "running",
        done: 0,
        total: res?.total ?? Math.max(0, to - from + 1),
        error: "",
      };
    } catch (e) {
      download.value = {
        state: "error",
        done: 0,
        total: 0,
        error: (e as Error).message || "下载失败",
      };
    }
  }

  async function cancelDownload(): Promise<void> {
    try {
      await audioApi.cancelDownload(bookId.value);
    } catch {
      // 忽略
    }
  }

  async function refreshCached(): Promise<void> {
    if (!bookId.value) return;
    try {
      const list = await audioApi.cachedAudio(bookId.value);
      cachedIndexes.value = list.map((x) => x.index);
    } catch {
      cachedIndexes.value = [];
    }
  }

  async function deleteChapterCache(indexes: number[]): Promise<void> {
    if (!bookId.value || !indexes.length) return;
    try {
      await audioApi.deleteAudioCache(bookId.value, indexes);
      await refreshCached();
    } catch {
      // 忽略
    }
  }

  return {
    // state
    bookId,
    bookName,
    coverUrl,
    origin,
    chapterIndex,
    chapterTitle,
    playUrl,
    totalChapters,
    cachedIndexes,
    status,
    errorMsg,
    positionMs,
    durationMs,
    bufferedMs,
    rate,
    volume,
    muted,
    playMode,
    autoNext,
    timerMinutes,
    timerRemainSec,
    download,
    // derived
    isActive,
    progressPct,
    bufferedPct,
    // control
    start,
    toggle,
    play,
    pause,
    stop,
    next,
    prev,
    jumpTo,
    seekMs,
    nudge,
    setRate,
    setVolume,
    setMuted,
    setAutoNext,
    cyclePlayMode,
    setTotalChapters,
    setTimer,
    setTimerMinutes,
    addTimer,
    onEnded,
    saveProgress,
    // cache
    downloadRange,
    cancelDownload,
    refreshCached,
    deleteChapterCache,
  };
});
