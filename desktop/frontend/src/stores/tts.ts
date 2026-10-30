/**
 * 朗读状态机。
 *
 * 职责边界：
 *   - **只认 `Segment`**，不关心段落来自 HTML 还是 PDF（M2 接 PDF 时这里一行不用改）；
 *   - 不直接访问 DOM。段落由「会话」（`TtsSession`，由阅读器提供）切好送进来，
 *     这样离开阅读器后已加载的段落仍能继续播放；
 *   - 进度回写走会话的 `save`，保持「单一写入源」——阅读器滚动也写同一个字段，
 *     但朗读期间阅读器会主动让位（见 ReaderView）。
 *
 * 竞态：每次换章/停止都自增 `generation`，过期回调一律丢弃
 * （翻章时上一章的回调很容易晚到）。
 */

import { defineStore } from "pinia";
import { computed, ref, shallowRef } from "vue";

import { SystemSpeaker } from "@/tts/SystemSpeaker";
import { loadTtsPrefs, saveTtsPrefs } from "@/tts/prefs";
import type { SegmentEl, TtsStatus, Voice } from "@/tts/types";
import { pickDefaultVoice, toVoice, watchSystemVoices } from "@/tts/voice";

/** 阅读器提供给朗读器的上下文。PDF 在 M2 里换成页实现，接口不变。 */
export interface TtsSession {
  bookId: number;
  bookName: string;
  /** 章节标题，用于播放条。 */
  chapterTitle: (chapter: number) => string;
  /** 提取某一章的段落（阅读器负责 DOM 切段）。 */
  extract: (chapter: number) => Promise<SegmentEl[]>;
  /** 翻到下一章并返回新章号；`null` 表示没有下一章。 */
  advance: (chapter: number) => Promise<number | null>;
  /** 把朗读位置落盘。`ratio` 是章内进度（0–1）。 */
  save: (chapter: number, segIndex: number, ratio: number) => void;
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, n));
}

export const useTtsStore = defineStore("tts", () => {
  const prefs = loadTtsPrefs();

  const status = ref<TtsStatus>("idle");
  const bookId = ref(0);
  const bookName = ref("");
  const chapter = ref(0);
  const chapterTitle = ref("");
  const segIndex = ref(0);
  const segments = shallowRef<SegmentEl[]>([]);
  const rate = ref(prefs.rate);
  const voiceId = ref(prefs.voiceId);
  const autoNext = ref(prefs.autoNext);
  const voices = ref<Voice[]>([]);
  const errorMsg = ref("");
  const generation = ref(0);

  const speaker = new SystemSpeaker();
  let session: TtsSession | null = null;
  let lastSaveAt = 0;
  /** 连续几个空章节：连续跳过会变成死循环，超过 2 个就报错停下。 */
  let emptyStreak = 0;

  const currentSegment = computed<SegmentEl | null>(
    () => segments.value[segIndex.value] ?? null,
  );
  const segCount = computed(() => segments.value.length);
  const isActive = computed(() => status.value !== "idle");
  const currentVoice = computed(
    () => voices.value.find((v) => v.id === voiceId.value) ?? null,
  );

  // 系统音色首帧为空，等就绪再填（见 tts/voice.ts 的说明）。
  watchSystemVoices((list) => {
    voices.value = list.map(toVoice);
    const pick = pickDefaultVoice(voices.value, voiceId.value);
    if (pick && !voiceId.value) voiceId.value = pick.id;
  });

  // ---------------- 会话绑定 ----------------

  /**
   * 阅读器挂载时绑定会话。
   *
   * 若正在读同一本书（离开阅读器后又回来），**不打断播放**，只重新提段落以恢复高亮锚点。
   * 正在读别的书则忽略，避免打开新书把当前朗读抢走。
   */
  function attach(next: TtsSession): boolean {
    if (isActive.value && bookId.value !== next.bookId) return false;
    session = next;
    bookId.value = next.bookId;
    bookName.value = next.bookName;
    if (isActive.value) void refreshSegments();
    return true;
  }

  /**
   * 阅读器卸载时解绑。
   *
   * **正在朗读就不解绑**：会话里有「离线切段」兜底（阅读器会话在拿不到 DOM 时
   * 会把 HTML 交给游离 document 切段），所以离开阅读器仍能自动续到下一章。
   * 读完后（idle）再进来会重新绑定。
   */
  function detach(book?: number) {
    if (book !== undefined && session && session.bookId !== book) return;
    if (!isActive.value) session = null;
  }

  /** 回到阅读器时刷新段落锚点（元素引用随组件卸载已失效）。 */
  async function refreshSegments() {
    if (!session) return;
    const ch = chapter.value;
    const gen = generation.value;
    const list = await session.extract(ch);
    if (gen !== generation.value || chapter.value !== ch) return;
    if (!list.length) return;
    segments.value = list;
    segIndex.value = clamp(segIndex.value, 0, list.length - 1);
  }

  // ---------------- 播放控制 ----------------

  async function start(
    next: TtsSession,
    opts: { chapter?: number; segIndex?: number } = {},
  ) {
    speaker.cancel();
    const gen = ++generation.value;
    session = next;
    bookId.value = next.bookId;
    bookName.value = next.bookName;
    errorMsg.value = "";
    emptyStreak = 0;
    status.value = "preparing";

    const ch = opts.chapter ?? 0;
    chapter.value = ch;
    const list = await next.extract(ch);
    if (gen !== generation.value) return;
    if (!list.length) {
      status.value = "error";
      errorMsg.value = "本章没有可朗读的文本";
      return;
    }
    segments.value = list;
    chapterTitle.value = next.chapterTitle(ch);
    segIndex.value = clamp(opts.segIndex ?? 0, 0, list.length - 1);
    play();
  }

  /** 朗读当前段。所有「从某段开始读」的路径最终都走这里。 */
  function play() {
    const seg = currentSegment.value;
    if (!seg) {
      void advanceChapter();
      return;
    }
    if (status.value !== "playing") status.value = "preparing";
    const gen = generation.value;
    speaker.speak({
      text: seg.text,
      voiceId: voiceId.value,
      rate: rate.value / 100,
      onStart: () => {
        if (gen === generation.value) status.value = "playing";
      },
      onEnd: () => {
        if (gen === generation.value) onSegmentEnd();
      },
      onError: (message) => {
        if (gen === generation.value) fail(message);
      },
    });
    persist();
  }

  function onSegmentEnd() {
    if (segIndex.value + 1 < segments.value.length) {
      segIndex.value += 1;
      persist();
      play();
      return;
    }
    void advanceChapter();
  }

  /** 章末：自动续读下一章；没有下一章或关了自动续读则停下。 */
  async function advanceChapter() {
    const s = session;
    if (!s || !autoNext.value) {
      finish();
      return;
    }
    const gen = ++generation.value;
    status.value = "preparing";
    const next = await s.advance(chapter.value);
    if (gen !== generation.value) return;
    if (next == null) {
      finish();
      return;
    }
    chapter.value = next;
    const list = await s.extract(next);
    if (gen !== generation.value) return;
    chapterTitle.value = s.chapterTitle(next);
    segments.value = list;
    segIndex.value = 0;
    if (!list.length) {
      // 空章节（书源偶尔给空正文、或阅读器已卸载且拿不到 HTML）跳过；
      // 连续空超过 2 章说明这条路走不通了，别无限递归。
      emptyStreak += 1;
      if (emptyStreak <= 2) {
        void advanceChapter();
        return;
      }
      fail("后续章节没有可朗读的文本");
      return;
    }
    emptyStreak = 0;
    play();
  }

  /** 读完全书：落盘后清空状态。 */
  function finish() {
    persist(true);
    speaker.cancel();
    status.value = "idle";
    segments.value = [];
    segIndex.value = 0;
    chapterTitle.value = "";
    errorMsg.value = "";
    emptyStreak = 0;
  }

  function pause() {
    if (status.value !== "playing" && status.value !== "preparing") return;
    speaker.cancel();
    status.value = "paused";
    persist(true);
  }

  function resume() {
    if (status.value !== "paused" && status.value !== "error") return;
    errorMsg.value = "";
    play();
  }

  function toggle() {
    if (status.value === "playing" || status.value === "preparing") pause();
    else if (status.value === "paused" || status.value === "error") resume();
  }

  function stop() {
    speaker.cancel();
    generation.value += 1;
    finish();
  }

  /** 上一段/下一段。暂停中只移动不播放，播放中立即换段。 */
  function step(delta: number) {
    if (!segments.value.length) return;
    const next = clamp(segIndex.value + delta, 0, segments.value.length - 1);
    if (next === segIndex.value) return;
    const paused = status.value === "paused" || status.value === "error";
    speaker.cancel();
    segIndex.value = next;
    persist();
    if (paused) {
      status.value = "paused";
      return;
    }
    play();
  }

  /** 从指定段开始读（点段落跳读）。 */
  function jumpTo(index: number) {
    if (!segments.value.length) return;
    speaker.cancel();
    segIndex.value = clamp(index, 0, segments.value.length - 1);
    persist();
    play();
  }

  /** 找到元素所属的段落下标；找不到返回 -1。 */
  function findSegmentIndex(target: Element | null): number {
    if (!target) return -1;
    const list = segments.value;
    for (let i = 0; i < list.length; i++) {
      const el = list[i].el;
      if (el === target || el.contains(target) || target.contains(el)) return i;
    }
    return -1;
  }

  // ---------------- 参数 ----------------

  /** 改语速：立即生效（重读当前段，避免旧的 rate 撑到段尾）。 */
  function setRate(pct: number) {
    rate.value = clamp(Math.round(pct), 50, 200);
    saveTtsPrefs({ rate: rate.value });
    if (status.value === "playing" || status.value === "preparing") {
      speaker.cancel();
      play();
    }
  }

  /** 换音色：不打断半句，下一段生效。 */
  function setVoice(id: string) {
    voiceId.value = id;
    saveTtsPrefs({ voiceId: id });
  }

  function setAutoNext(on: boolean) {
    autoNext.value = on;
    saveTtsPrefs({ autoNext: on });
  }

  // ---------------- 进度 ----------------

  /** 回写进度（1.5s 节流；章末/暂停/停止强制写）。 */
  function persist(force = false) {
    if (!session) return;
    const now = Date.now();
    if (!force && now - lastSaveAt < 1500) return;
    lastSaveAt = now;
    const total = segments.value.length || 1;
    const ratio = Math.min(1, (segIndex.value + 1) / total);
    session.save(chapter.value, segIndex.value, ratio);
  }

  function fail(message: string) {
    speaker.cancel();
    status.value = "error";
    errorMsg.value = message;
  }

  return {
    // state
    status,
    bookId,
    bookName,
    chapter,
    chapterTitle,
    segIndex,
    segments,
    rate,
    voiceId,
    voices,
    autoNext,
    errorMsg,
    // derived
    currentSegment,
    segCount,
    isActive,
    currentVoice,
    // session
    attach,
    detach,
    refreshSegments,
    // control
    start,
    play,
    pause,
    resume,
    toggle,
    stop,
    step,
    jumpTo,
    findSegmentIndex,
    // params
    setRate,
    setVoice,
    setAutoNext,
  };
});
