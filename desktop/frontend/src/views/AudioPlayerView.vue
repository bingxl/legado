<script setup lang="ts">
/**
 * 听书播放页（独立布局）。
 *
 * 播放状态与音频元素都在 stores/audioPlayer 里，本页只负责：取书籍信息 / 目录 /
 * 进度、把控件事件转给 store、以及路由记账。从常驻播放条回到本页时若同一本书
 * 正在播，绝不重新 start（否则会把进度打回起点）。
 */
import { computed, onMounted, ref, watch } from "vue";
import { onBeforeRouteLeave, useRoute, useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { bookshelfApi } from "@/api/bookshelf";
import { readerApi } from "@/api/reader";
import { useAudioPlayerStore } from "@/stores/audioPlayer";
import { useBookshelfStore } from "@/stores/bookshelf";
import { copyText } from "@/utils/clipboard";
import { coverURL } from "@/utils/media";
import { smartBack } from "@/utils/nav";
import { loadReaderPrefs } from "@/utils/readerPrefs";
import type { AudioBookLike, AudioChapterLike, PlayMode } from "@/types/audio";
import type { BookDetail } from "@/types";

const props = defineProps<{ id: string | number }>();
const route = useRoute();
const router = useRouter();
const audio = useAudioPlayerStore();

const bookId = computed(() => Number(props.id) || 0);
const bookInfo = ref<BookDetail | null>(null);
const chapters = ref<AudioChapterLike[]>([]);
const loading = ref(true);
const drawer = ref(false);

const RATE_PRESETS = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3];
const PLAY_MODE_LABELS: Record<PlayMode, string> = {
  LIST_END_STOP: "列表结束停止",
  SINGLE_LOOP: "单曲循环",
  RANDOM: "随机播放",
  LIST_LOOP: "列表循环",
};

const queryIndex = computed(() => {
  const raw = route.query.index;
  if (raw === undefined) return undefined;
  const n = Number(raw);
  return Number.isFinite(n) ? Math.trunc(n) : undefined;
});

const bookName = computed(
  () => bookInfo.value?.name || audio.bookName || "听书",
);
const author = computed(() => bookInfo.value?.author || "");
const coverSrc = computed(() =>
  coverURL(audio.coverUrl || bookInfo.value?.cover || ""),
);
const bgStyle = computed(() => {
  const c = coverURL(audio.coverUrl || bookInfo.value?.cover || "");
  return c ? { backgroundImage: `url(${c})` } : {};
});

const playLabel = computed(() => {
  if (audio.status === "loading") return "…";
  if (audio.status === "playing") return "暂停";
  if (audio.status === "error") return "重试";
  return "播放";
});

// 进度条：拖动期间只跟本地 dragPct，松手才 seek 并落盘（对齐 ChapterProgress）。
const trackRef = ref<HTMLElement | null>(null);
const dragging = ref(false);
const dragPct = ref(0);
const shownPct = computed(() =>
  dragging.value ? dragPct.value : audio.progressPct,
);
const shownMs = computed(() =>
  dragging.value && audio.durationMs > 0
    ? (dragPct.value / 100) * audio.durationMs
    : audio.positionMs,
);

const isCached = computed(() =>
  audio.cachedIndexes.includes(audio.chapterIndex),
);
const downloadLabel = computed(() => {
  const d = audio.download;
  if (d.state === "running") return `下载中 ${d.done}/${d.total}`;
  if (d.state === "error") return `下载失败：${d.error}`;
  if (d.state === "canceled") return "下载已取消";
  if (d.state === "done") return "下载完成";
  return "";
});

function fmtClock(ms: number): string {
  const total = Math.max(0, Math.floor((Number.isFinite(ms) ? ms : 0) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
}

/** 目录里的时长是毫秒（见 DTO ChapterItem.duration），折算成 mm:ss。 */
function fmtDuration(ms?: number): string {
  if (!ms || ms <= 0) return "";
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}

function pctAt(clientX: number): number {
  const r = trackRef.value?.getBoundingClientRect();
  if (!r || r.width <= 0) return 0;
  return Math.max(0, Math.min(100, ((clientX - r.left) / r.width) * 100));
}

function onPointerDown(e: PointerEvent) {
  if (audio.durationMs <= 0) return;
  e.preventDefault();
  dragging.value = true;
  dragPct.value = pctAt(e.clientX);
  try {
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  } catch {
    // 少数环境不支持指针捕获，退化成「只在轨道内跟随」
  }
}
function onPointerMove(e: PointerEvent) {
  if (!dragging.value) return;
  dragPct.value = pctAt(e.clientX);
}
function onPointerUp(e: PointerEvent) {
  if (!dragging.value) return;
  dragging.value = false;
  try {
    const el = e.currentTarget as HTMLElement;
    if (el.hasPointerCapture?.(e.pointerId)) el.releasePointerCapture(e.pointerId);
  } catch {
    // 没有捕获就没有可释放的
  }
  // 只在抬手时 seek + 落盘
  audio.seekMs((dragPct.value / 100) * audio.durationMs);
}

/** 用 vue-router 的 replace 记账章节：安卓返回键只认路由历史。 */
function replaceIndexQuery(index: number) {
  const q: Record<string, string> = {};
  for (const [k, v] of Object.entries(route.query)) {
    if (typeof v === "string") q[k] = v;
  }
  q.index = String(index);
  return router.replace({ path: route.path, query: q });
}

async function loadMeta(): Promise<void> {
  try {
    const [book, list] = await Promise.all([
      bookshelfApi.getBook(bookId.value),
      readerApi.getChapters(bookId.value),
    ]);
    bookInfo.value = book;
    chapters.value = (list ?? []).map((c) => {
      const cl = c as unknown as AudioChapterLike;
      return { index: c.index, title: c.title, duration: cl.duration ?? 0 };
    });
    audio.setTotalChapters(chapters.value.length || book.totalChapters || 0);
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

onMounted(async () => {
  await loadMeta();
  // 从常驻播放条回来：同一本书正在播，不打断，只把 query 对齐到当前章。
  if (audio.isActive && audio.bookId === bookId.value) {
    void replaceIndexQuery(audio.chapterIndex);
    return;
  }

  let index = 0;
  let posMs = 0;
  try {
    const p = await readerApi.getProgress(bookId.value);
    if (p && p.chapterIndex >= 0) {
      index = p.chapterIndex;
      // 音频书里 GetProgress 的 chapterPos 就是播放毫秒，直接用于恢复。
      posMs = Math.max(0, Math.round(p.chapterPos || 0));
    }
  } catch {
    // 没有进度记录，从第一章开始
  }
  if (queryIndex.value !== undefined) {
    index = Math.max(0, queryIndex.value);
    posMs = 0; // 详情页指定了章节，一律从 0 开始
  }

  const b = bookInfo.value as unknown as AudioBookLike | null;
  void audio.start({
    bookId: bookId.value,
    bookName: b?.name || "听书",
    // DTO 封面字段是 cover（不是 coverUrl），转成 store 内部的 coverUrl。
    coverUrl: bookInfo.value?.cover || "",
    origin: b?.origin || "",
    index,
    positionMs: posMs,
  });
  void replaceIndexQuery(index);
});

// 切章（含自动续播）都把章节号记进 query，返回键才不会退回上一个 tab。
watch(
  () => audio.chapterIndex,
  (idx) => {
    if (!audio.isActive || route.name !== "audio") return;
    if (String(route.query.index ?? "") !== String(idx)) {
      void replaceIndexQuery(idx);
    }
  },
);

/**
 * 试读（发现/搜索点开、从未入架）离开时询问是否加入书架。
 *
 * 与阅读器（ReaderView）同一套口径：**先看设置里「返回时提示加入书架」**，
 * 开关关着就直接放行。此前这里漏了这一步判定，导致听书不管设置如何都会弹框，
 * 而书籍/漫画遵守设置——同一个开关在两处表现不一致。
 *
 * 放在路由离开守卫里：卸载时组件已在拆，弹不出对话框也拿不到选择。
 */
let prompting = false;
onBeforeRouteLeave(async () => {
  // 每次都现读：用户可能刚在设置页改完就回来，不必重启应用。
  if (!loadReaderPrefs().promptAddToShelf) return true;
  const b = bookInfo.value;
  if (!b || b.inShelf !== false) return true;
  if (prompting) return false;
  prompting = true;
  let add = false;
  try {
    await ElMessageBox.confirm(
      `《${b.name}》还不在书架中，要把它加入书架吗？`,
      "加入书架",
      {
        confirmButtonText: "加入书架",
        cancelButtonText: "暂不加入",
        type: "info",
        closeOnClickModal: false,
      },
    );
    add = true;
  } catch {
    add = false;
  } finally {
    prompting = false;
  }
  if (!add) return true;
  try {
    await bookshelfApi.putOnShelf(bookId.value);
    b.inShelf = true;
    ElMessage.success(`《${b.name}》已加入书架`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
  // 与阅读器一致：入架后立刻刷新书架列表，切回书架不用手动刷新。
  void useBookshelfStore().loadBooks();
  return true;
});

function goBack() {
  smartBack(router, "/");
}
function selectChapter(index: number) {
  drawer.value = false;
  audio.jumpTo(index);
}
function nudgeRate(delta: number) {
  audio.setRate(audio.rate + delta);
}
function onRateSelect(v: number) {
  audio.setRate(v);
}
function onVolumeChange(v: number) {
  audio.setVolume(v / 100);
}
function onTimerChange(v: number) {
  audio.setTimer(v);
}
function downloadThis() {
  void audio.downloadRange(bookId.value, audio.chapterIndex, audio.chapterIndex);
}
function downloadRemaining() {
  const total = audio.totalChapters || chapters.value.length;
  const to = Math.max(audio.chapterIndex, total - 1);
  void audio.downloadRange(bookId.value, audio.chapterIndex, to);
}
function deleteThisCache() {
  void audio.deleteChapterCache([audio.chapterIndex]);
}
async function copyDebug() {
  const lines = [
    `bookId=${bookId.value}`,
    `book=${bookName.value}`,
    `origin=${audio.origin}`,
    `chapter=${audio.chapterIndex} ${audio.chapterTitle}`,
    `playUrl=${audio.playUrl}`,
    `status=${audio.status}`,
    `error=${audio.errorMsg}`,
    `positionMs=${audio.positionMs} durationMs=${audio.durationMs} bufferedMs=${audio.bufferedMs}`,
    `rate=${audio.rate} volume=${audio.volume} muted=${audio.muted}`,
    `playMode=${audio.playMode} autoNext=${audio.autoNext}`,
    `timer=${audio.timerMinutes}m remain=${audio.timerRemainSec}s`,
  ];
  if (await copyText(lines.join("\n"))) ElMessage.success("已复制调试信息");
  else ElMessage.error("复制失败");
}
</script>

<template>
  <div class="audio-view" v-loading="loading">
    <div class="audio-bg" :style="bgStyle" />
    <div class="audio-bg-mask" />

    <header class="bar">
      <button class="back" title="返回" @click="goBack">
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M15 5l-7 7 7 7" /></svg>
      </button>
      <span class="bar-title">听书</span>
      <div class="bar-fill" />
      <button class="link-btn" @click="drawer = true">目录</button>
      <button class="link-btn" @click="copyDebug">调试</button>
    </header>

    <div class="stage">
      <div class="stage-inner">
        <div class="stage-cover">
          <div class="cover-wrap" :class="{ spinning: audio.status === 'playing' }">
            <img v-if="coverSrc" class="cover" :src="coverSrc" :alt="bookName" />
            <div v-else class="cover-fallback">{{ bookName.slice(0, 1) }}</div>
          </div>
        </div>

        <div class="stage-main">
          <h1 class="book-name" :title="bookName">{{ bookName }}</h1>
          <div class="author">{{ author || "佚名" }}</div>
          <div class="chapter-name" :title="audio.chapterTitle">
            {{ audio.chapterTitle || "准备中…" }}
          </div>
          <div v-if="audio.status === 'error'" class="error">{{ audio.errorMsg }}</div>

          <!-- 进度与时间同行且绝不换行；窄屏让溢出发生在这一行自己身上 -->
          <div class="progress-scroll">
            <div class="progress-row">
              <span class="time">{{ fmtClock(shownMs) }}</span>
              <div
                ref="trackRef"
                class="track"
                role="slider"
                aria-label="播放进度"
                aria-valuemin="0"
                aria-valuemax="100"
                :aria-valuenow="Math.round(shownPct)"
                @pointerdown="onPointerDown"
                @pointermove="onPointerMove"
                @pointerup="onPointerUp"
                @pointercancel="onPointerUp"
              >
                <div class="buffered" :style="{ width: audio.bufferedPct + '%' }" />
                <div class="fill" :style="{ width: shownPct + '%' }" />
                <span class="thumb" :style="{ left: shownPct + '%' }" />
              </div>
              <span class="time">{{ fmtClock(audio.durationMs) }}</span>
            </div>
          </div>

          <!-- 走带：上一章 / 快退 / 播放 / 快进 / 下一章 -->
          <div class="transport">
            <button class="ctl" @click="audio.prev()">上一章</button>
            <button class="ctl" @click="audio.nudge(-15)">-15s</button>
            <button class="ctl play" @click="audio.toggle()">{{ playLabel }}</button>
            <button class="ctl" @click="audio.nudge(15)">+15s</button>
            <button class="ctl" @click="audio.next()">下一章</button>
          </div>

          <!-- 参数区：可换行，但不隐藏任何按钮文字 -->
          <div class="options">
            <div class="opt">
              <span class="opt-label">倍速</span>
              <el-select
                class="rate-select r-fit"
                style="--r-fit-w: 96px"
                size="small"
                :model-value="audio.rate"
                @change="onRateSelect"
              >
                <el-option
                  v-for="r in RATE_PRESETS"
                  :key="r"
                  :label="r + '×'"
                  :value="r"
                />
              </el-select>
              <button class="mini" title="减速 0.1" @click="nudgeRate(-0.1)">-0.1</button>
              <button class="mini" title="加速 0.1" @click="nudgeRate(0.1)">+0.1</button>
              <span class="opt-value">{{ audio.rate.toFixed(1) }}×</span>
            </div>

            <div class="opt">
              <span class="opt-label">音量</span>
              <el-slider
                class="volume-slider"
                :model-value="Math.round(audio.volume * 100)"
                :min="0"
                :max="100"
                :step="1"
                @change="onVolumeChange"
              />
              <button class="mini" @click="audio.setMuted(!audio.muted)">
                {{ audio.muted ? "取消静音" : "静音" }}
              </button>
            </div>

            <div class="opt">
              <span class="opt-label">模式</span>
              <button class="ctl mode" @click="audio.cyclePlayMode()">
                {{ PLAY_MODE_LABELS[audio.playMode] }}
              </button>
            </div>

            <div class="opt">
              <span class="opt-label">定时</span>
              <el-slider
                class="timer-slider"
                :model-value="audio.timerMinutes"
                :min="0"
                :max="180"
                :step="1"
                @change="onTimerChange"
              />
              <span class="opt-value">{{ audio.timerMinutes }} 分钟</span>
              <button class="mini" @click="audio.addTimer(10)">+10 分钟</button>
              <span v-if="audio.timerRemainSec > 0" class="opt-value remain">
                剩余 {{ fmtClock(audio.timerRemainSec * 1000) }}
              </span>
            </div>
          </div>

          <!-- 缓存 / 下载 -->
          <div class="cache-ops">
            <span v-if="isCached" class="cached-tag">本章已缓存</span>
            <button class="mini" @click="downloadThis">下载本章</button>
            <button class="mini" @click="downloadRemaining">下载剩余</button>
            <button class="mini" @click="audio.cancelDownload()">取消下载</button>
            <button v-if="isCached" class="mini" @click="deleteThisCache">删本章缓存</button>
            <span v-if="downloadLabel" class="download-state">{{ downloadLabel }}</span>
          </div>
        </div>
      </div>
    </div>

    <el-drawer v-model="drawer" title="目录" size="320px" direction="rtl">
      <div class="toc">
        <button
          v-for="c in chapters"
          :key="c.index"
          class="toc-item"
          :class="{ active: c.index === audio.chapterIndex }"
          @click="selectChapter(c.index)"
        >
          <span class="toc-title">{{ c.title || `第 ${c.index + 1} 章` }}</span>
          <span v-if="audio.cachedIndexes.includes(c.index)" class="toc-cached">已缓存</span>
          <span v-if="fmtDuration(c.duration)" class="toc-dur">{{ fmtDuration(c.duration) }}</span>
        </button>
        <p v-if="!chapters.length" class="toc-empty">这本书还没有目录</p>
      </div>
    </el-drawer>
  </div>
</template>

<style scoped>
.audio-view {
  position: relative;
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  min-width: 0;
  overflow: hidden;
  background: #fff;
}
.audio-bg {
  position: absolute;
  inset: -60px;
  background-size: cover;
  background-position: center;
  filter: blur(60px) brightness(1.05);
  opacity: 0.35;
  transform: scale(1.1);
  pointer-events: none;
}
.audio-bg-mask {
  position: absolute;
  inset: 0;
  background: linear-gradient(180deg, rgba(255, 255, 255, 0.5), #fff 70%);
  pointer-events: none;
}

.bar {
  position: relative;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  flex: none;
  min-width: 0;
  min-height: 52px;
  padding: var(--r-pad-sm) var(--r-pad);
  border-bottom: 1px solid rgba(0, 0, 0, 0.06);
}
.bar-title {
  font-size: 16px;
  font-weight: 600;
  color: #111827;
}
.bar-fill {
  flex: 1;
}
.back {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
  width: 30px;
  height: 30px;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: transparent;
  cursor: pointer;
}
.back:hover {
  background: rgba(0, 0, 0, 0.06);
}
.back svg {
  width: 20px;
  height: 20px;
  fill: none;
  stroke: #374151;
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.link-btn {
  flex: none;
  padding: 4px 10px;
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius-sm);
  background: #fff;
  font-size: 13px;
  color: #374151;
  cursor: pointer;
}
.link-btn:hover {
  background: #f3f4f6;
}

.stage {
  position: relative;
  flex: 1;
  min-height: 0;
  min-width: 0;
  overflow: auto;
  padding: var(--r-pad);
  text-align: center;
}
/* 内层至少撑满一屏：内容超长时正常滚动。
   若把 align-items:center 直接放在滚动容器上，内容超高会把顶部裁掉且滚不上去。 */
.stage-inner {
  display: flex;
  flex-direction: row;
  align-items: center;
  justify-content: center;
  gap: clamp(24px, 4vw, 56px);
  min-height: 100%;
  min-width: 0;
}
/* 舞台子项一律不参与收缩。
   纵向布局时容器高度不够，子项默认会被压到比内容还矮，文字随即被
   overflow:hidden 切成半截（标题/作者/章节名/时间全变半行）。
   正确行为是让 stage 自己滚动，而不是压扁行高。 */
.stage-inner > * {
  flex: none;
}
.stage-cover {
  display: flex;
  flex: none;
}
/* 右侧信息列：桌面端封面在左、正文控件在右，矮窗口也不会被挤成一列。
   左对齐让标题紧贴封面，不会在中间留下一大片空白。 */
.stage-main {
  flex: 0 1 560px;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: stretch;
  gap: 8px;
  text-align: left;
}
.stage-main > * {
  flex: none;
}
.stage-main .transport,
.stage-main .options,
.stage-main .cache-ops {
  justify-content: flex-start;
}
.cover-wrap {
  /* 封面同时受宽、高约束：矮窗口先缩封面，把高度留给文字与控件，
     避免整页被挤到只剩滚动条。22vh 在 800 高时约 170px。 */
  --cover: min(46vw, 220px, 22vh);
  flex: none;
  width: var(--cover);
  height: var(--cover);
  border-radius: 50%;
  overflow: hidden;
  background: #eef2ff;
  box-shadow: 0 8px 28px rgba(15, 23, 42, 0.16);
}
.cover-wrap.spinning {
  animation: spin 24s linear infinite;
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}
.cover {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.cover-fallback {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  font-size: 56px;
  color: #a5b4fc;
}
.book-name {
  margin: 6px 0 0;
  max-width: min(100%, 520px);
  min-width: 0;
  font-size: 20px;
  line-height: 1.4;
  font-weight: 600;
  color: #111827;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.author {
  font-size: 13px;
  line-height: 1.5;
  color: #6b7280;
}
.chapter-name {
  max-width: min(100%, 520px);
  min-width: 0;
  font-size: 14px;
  line-height: 1.45;
  color: #374151;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.error {
  max-width: min(100%, 520px);
  min-width: 0;
  font-size: 13px;
  color: #b91c1c;
}

/* 进度行：nowrap，窄屏让溢出发生在容器自身 */
.progress-scroll {
  width: 100%;
  max-width: min(100%, 560px);
  min-width: 0;
  overflow-x: auto;
  -webkit-overflow-scrolling: touch;
  margin-top: 8px;
}
.progress-row {
  display: flex;
  align-items: center;
  flex-wrap: nowrap;
  white-space: nowrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  padding: 4px 0;
}
.time {
  flex: none;
  min-width: 42px;
  font-size: 12px;
  color: #6b7280;
  font-variant-numeric: tabular-nums;
  text-align: center;
}
.track {
  position: relative;
  flex: 1;
  min-width: 90px;
  height: 6px;
  border-radius: 3px;
  background: #e5e7eb;
  cursor: pointer;
  touch-action: none;
}
.track::before {
  content: "";
  position: absolute;
  inset: -8px 0;
}
.buffered {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: 3px;
  background: #c7d2fe;
}
.fill {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: 3px;
  background: #4338ca;
}
.thumb {
  position: absolute;
  top: 50%;
  width: 12px;
  height: 12px;
  margin-left: -6px;
  border: 2px solid #4338ca;
  border-radius: 50%;
  background: #fff;
  transform: translateY(-50%);
}

.transport,
.cache-ops {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  justify-content: center;
  gap: var(--r-gap-sm);
  width: 100%;
  max-width: min(100%, 620px);
  min-width: 0;
  margin-top: 6px;
}
/* 参数区：整项一起换行，绝不把单个控件拆到两行；标签定宽保证纵向对齐。 */
.options {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: center;
  gap: 8px var(--r-gap);
  width: 100%;
  max-width: min(100%, 620px);
  min-width: 0;
  margin-top: 6px;
}
.ctl {
  flex: none;
  min-height: 34px;
  padding: 0 12px;
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius-sm);
  background: #fff;
  font-size: 13px;
  color: #374151;
  cursor: pointer;
  white-space: nowrap;
}
.ctl:hover {
  background: #f3f4f6;
}
.ctl.play {
  min-width: 72px;
  font-weight: 600;
  color: #4338ca;
  border-color: #c7d2fe;
  background: #eef2ff;
}
.ctl.play:hover {
  background: #e0e7ff;
}
.mini {
  flex: none;
  min-height: 30px;
  padding: 0 10px;
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius-sm);
  background: #fff;
  font-size: 12px;
  color: #374151;
  cursor: pointer;
  white-space: nowrap;
}
.mini:hover {
  background: #f3f4f6;
}
.opt {
  display: flex;
  align-items: center;
  flex-wrap: nowrap;
  justify-content: center;
  gap: var(--r-gap-sm);
  flex: none;
  min-width: 0;
}
/* 整行不换行，但控件自身也不能被压扁：给出明确宽度。
   `.r-fit` 用的是 min(100%, …)，在 shrink-to-fit 的 .opt 里百分比会塌成几十像素。 */
.opt > * {
  flex: none;
}
.rate-select {
  width: 96px;
}
.opt-label {
  flex: none;
  width: 36px;
  text-align: right;
  font-size: 12px;
  color: #6b7280;
}
.opt-value {
  flex: none;
  font-size: 12px;
  color: #6b7280;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}
.opt-value.remain {
  color: #4338ca;
}
.volume-slider,
.timer-slider {
  width: 130px;
  max-width: 100%;
}
.download-state {
  flex: none;
  font-size: 12px;
  color: #6b7280;
  white-space: nowrap;
}
.cached-tag {
  flex: none;
  padding: 2px 8px;
  border-radius: 10px;
  background: #e8f5e9;
  color: #2e7d32;
  font-size: 12px;
  white-space: nowrap;
}

/* 目录抽屉 */
.toc {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.toc-item {
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  min-width: 0;
  padding: 9px 10px;
  border: none;
  border-bottom: 1px solid #f3f4f6;
  background: transparent;
  font-size: 13px;
  color: #374151;
  text-align: left;
  cursor: pointer;
}
.toc-item:hover {
  background: #f9fafb;
}
.toc-item.active {
  color: #4338ca;
  background: #eef2ff;
  font-weight: 600;
}
.toc-title {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.toc-cached,
.toc-dur {
  flex: none;
  font-size: 11px;
  color: #9ca3af;
  white-space: nowrap;
}
.toc-empty {
  padding: 24px 0;
  text-align: center;
  font-size: 13px;
  color: #9ca3af;
}

/* 窄屏（含手机）：回到「上封面、下控件」的单列布局，恢复居中。 */
@media (max-width: 900px) {
  .stage-inner {
    flex-direction: column;
    align-items: center;
    justify-content: flex-start;
    gap: 8px;
  }
  .stage-main {
    flex: 0 0 auto;
    width: 100%;
    align-items: center;
    text-align: center;
  }
  .stage-main .transport,
  .stage-main .options,
  .stage-main .cache-ops {
    justify-content: center;
  }
}

@media (max-width: 640px) {
  .stage-inner {
    gap: 8px;
  }
  .cover-wrap {
    --cover: min(52vw, 180px, 24vh);
  }
  .options,
  .cache-ops {
    gap: 6px;
  }
}

/* 矮窗口（横向拉伸的桌面窗口、安卓横屏）：封面已按 vh 自动收缩，
   这里只压缩间距，保证主控件不被挤出首屏。 */
@media (max-height: 560px) {
  .stage {
    padding-top: 6px;
    gap: 6px;
  }
  .book-name {
    margin-top: 2px;
    font-size: 17px;
  }
}
</style>
