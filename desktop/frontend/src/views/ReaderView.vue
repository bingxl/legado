<script setup lang="ts">
/**
 * 阅读器。
 *
 * 按书籍格式选择渲染方式：
 *   - pdf   ：交给 WebView 内置的 PDF 能力（<iframe src="/raw/?p=...">）
 *   - comic ：图片流（后端已把压缩包解压到缓存目录）
 *   - 其它  ：正文 HTML
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { ElMessage } from "element-plus";

import { readerApi } from "@/api/reader";
import { bookshelfApi } from "@/api/bookshelf";
import { CacheScope, cacheApi } from "@/api/cache";
import { rawFileURL } from "@/api/system";
import { jobPercent, useCacheStore } from "@/stores/cache";
import { useTtsStore } from "@/stores/tts";
import { domSegment } from "@/tts/domSegment";
import { segmentHTML } from "@/tts/offlineSegment";
import type { TtsSession } from "@/stores/tts";
import { copyText } from "@/utils/clipboard";
import { comicImageURL } from "@/utils/media";
import { loadReaderPrefs, saveReaderPrefs } from "@/utils/readerPrefs";
import { wrapPlainTextAsParagraphs } from "@/utils/plainText";
import type { BookDetail, ChapterContent, ChapterItem } from "@/types";

const route = useRoute();
const router = useRouter();
const tts = useTtsStore();
const cache = useCacheStore();

const bookId = computed(() => Number(route.params.id || 0));
const book = ref<BookDetail | null>(null);
const chapters = ref<ChapterItem[]>([]);
const content = ref<ChapterContent | null>(null);
const index = ref(0);
const loading = ref(false);
const tocVisible = ref(false);
const stageRef = ref<HTMLElement | null>(null);
/** 已缓存的章节序号，用于目录里打标记。 */
const cachedIndexes = ref<Set<number>>(new Set());

/**
 * 进入这本书时的稳定 id。
 *
 * `bookId` 来自路由参数，**离开阅读器后会变成 0**；而朗读会话在离开后仍要继续
 * 拉下一章、写进度，用它就会打出「参数不合法: 缺少书籍 ID」。所以所有
 * 「离开后仍可能执行」的操作都读这个值。
 */
const boundBookId = ref(0);

/** 正文/漫画的滚动容器（二者互斥渲染，PDF 由 iframe 自己管）。 */
function scroller(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".text, .comic") ?? null;
}

// 阅读偏好：字号/行距跨会话记住（否则每次进阅读器都要重调）
const prefs = loadReaderPrefs();
const fontSize = ref(prefs.fontSize);
const lineHeight = ref(prefs.lineHeight);
watch([fontSize, lineHeight], ([size, height]) =>
  saveReaderPrefs({ fontSize: size, lineHeight: height }),
);

const isPdf = computed(() => book.value?.format === "pdf");
/** 漫画：本地漫画文件，或网络漫画源的章节图片流（后端已把 <img> 抽成 images）。 */
const isComic = computed(
  () => book.value?.format === "comic" || (content.value?.images?.length ?? 0) > 0,
);

/** 当前正在朗读的是不是这本书（含暂停）。 */
const readingThisBook = computed(
  () => tts.isActive && tts.bookId === boundBookId.value,
);
/** 只有纯文本类支持朗读；漫画无字、PDF 待 M2 的 pdf.js 文本层。 */
const canRead = computed(() => !!book.value && !isPdf.value && !isComic.value);

const cacheLabel = computed(() => {
  const job = cacheJob.value;
  if (job?.state === "running") return `缓存中 ${jobPercent(job)}%`;
  return "缓存";
});

const readLabel = computed(() => {
  if (!readingThisBook.value) return "▶ 朗读";
  if (tts.status === "playing" || tts.status === "preparing") return "⏸ 暂停";
  return "▶ 继续";
});

/** 复制书籍地址：网络书是详情页 URL，本地书是文件路径。 */
async function copyBookURL() {
  const url = book.value?.bookUrl;
  if (!url) {
    ElMessage.warning("这本书没有可复制的地址");
    return;
  }
  if (await copyText(url)) ElMessage.success("已复制书籍地址");
  else ElMessage.error("复制失败，请手动复制");
}

/**
 * 正文渲染用 HTML。
 *
 * 有的书源正文是一段带换行的纯文本（没有 `<p>`），直接 v-html 会折成一整面墙；
 * 这里按行补成段落（含标签的 HTML 原样通过，见 utils/plainText.ts）。
 */
const displayHTML = computed(() =>
  wrapPlainTextAsParagraphs(content.value?.html ?? ""),
);

/** 当前书的缓存任务（运行中时 toolbar 显示进度）。 */
const cacheJob = computed(() => cache.jobOf(boundBookId.value));
/** 本地书本身就是本地文件，缓存没有意义。 */
const canCache = computed(() => !!book.value && book.value.kind !== "local");

/** PDF 直读地址：本地路径经后端 /raw/ 路由暴露。 */
const pdfURL = computed(() =>
  book.value ? rawFileURL(book.value.bookUrl) : "",
);

async function loadMeta() {
  boundBookId.value = bookId.value;
  book.value = await bookshelfApi.getBook(bookId.value);
  chapters.value = await readerApi.getChapters(bookId.value);
  await refreshCachedIndexes();
  const p = await readerApi.getProgress(bookId.value);
  // 详情页点某一章进来时带 ?index=N，优先于上次阅读进度。
  const want = Number(route.query.index);
  if (Number.isFinite(want) && want >= 0 && Math.trunc(want) < chapters.value.length) {
    index.value = Math.trunc(want);
    return;
  }
  index.value = p.chapterIndex >= 0 ? p.chapterIndex : 0;
}

/** 重新拉取已缓存章节（缓存任务结束后目录标记要跟着变）。 */
async function refreshCachedIndexes() {
  if (!boundBookId.value) return;
  try {
    const list = await cacheApi.chapters(boundBookId.value);
    cachedIndexes.value = new Set(list.map((c) => c.index));
  } catch {
    // 目录标记属于锦上添花，取不到就当没有缓存，不打断阅读。
    cachedIndexes.value = new Set();
  }
}

/** 缓存菜单：本章 / 剩余 / 整本 / 去管理页。 */
async function onCacheCommand(command: string) {
  if (!book.value) return;
  if (!canCache.value) {
    ElMessage.warning("本地书无需缓存");
    return;
  }
  if (command === "manage") {
    router.push("/cache");
    return;
  }
  try {
    if (command === "chapter") {
      await cache.start(boundBookId.value, CacheScope.Chapters, [index.value]);
      ElMessage.success(`已开始缓存「${content.value?.title || "本章"}」`);
      return;
    }
    const scope =
      command === "all" ? CacheScope.All : CacheScope.Remaining;
    await cache.start(boundBookId.value, scope);
    ElMessage.success(command === "all" ? "已开始缓存整本" : "已开始缓存剩余章节");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 任务结束后刷新目录上的缓存标记。 */
watch(
  () => cacheJob.value?.state,
  async (state, prev) => {
    if (prev === "running" && state && state !== "running") {
      await refreshCachedIndexes();
    }
  },
);

/** 返回上一页（详情页或书架）；直接打开阅读器时退回书架。 */
function goBack() {
  if (window.history.length > 1) router.back();
  else router.push("/");
}

/** 载入某章。返回是否成功——朗读自动翻章要靠它判断能不能继续。 */
async function loadChapter(i: number): Promise<boolean> {
  loading.value = true;
  try {
    content.value = await readerApi.getContent(boundBookId.value, i);
    index.value = i;
    // 换章后必须回到顶部，否则新章节会继承上一章的滚动位置。
    await nextTick();
    const sc = scroller();
    if (sc) sc.scrollTop = 0;
    await persistProgress(0);
    return true;
  } catch (e) {
    ElMessage.error((e as Error).message);
    return false;
  } finally {
    loading.value = false;
  }
}

/**
 * 用户手动换章（上一章/下一章/目录）。
 * 朗读中要跟着换到新章，否则会出现「页面在第 5 章、声音还在念第 3 章」。
 */
async function userLoadChapter(i: number) {
  const ok = await loadChapter(i);
  if (!ok || !readingThisBook.value) return;
  await tts.start(session, { chapter: i, segIndex: 0 });
}

function prev() {
  if (loading.value) return;
  if (index.value > 0) void userLoadChapter(index.value - 1);
}
function next() {
  if (loading.value) return;
  if (content.value && content.value.nextIndex >= 0) {
    void userLoadChapter(content.value.nextIndex);
  }
}

/**
 * 阅读区点击翻页：左 1/3 上一章、右 1/3 下一章。
 * 中间 1/3 不响应，留给选词和滚轮，避免误翻页。
 */
function onStageClick(e: MouseEvent) {
  const el = stageRef.value;
  if (!el) return;

  const target = e.target as HTMLElement;
  // 目录、链接、表单控件等交互元素不参与翻页。
  if (target.closest("a, button, input, textarea, select, .toc")) return;
  // 有选中文字时说明用户在选词，不要抢这一下点击。
  if (window.getSelection()?.toString()) return;

  // 朗读中：点正文 = 从这一段开始读（优先于左右三分之一的翻页）。
  if (readingThisBook.value && target.closest(".content")) {
    const idx = tts.findSegmentIndex(target);
    if (idx >= 0) {
      tts.jumpTo(idx);
      return;
    }
  }

  const rect = el.getBoundingClientRect();
  if (rect.width === 0) return;
  const ratio = (e.clientX - rect.left) / rect.width;
  if (ratio < 1 / 3) prev();
  else if (ratio > 2 / 3) next();
}

/** 左右方向键翻章；输入框或带修饰键的按键不接管。 */
function onKeydown(e: KeyboardEvent) {
  if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) {
    return;
  }
  const target = e.target as HTMLElement | null;
  if (
    target &&
    (/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable)
  ) {
    return;
  }
  if (e.key === "ArrowLeft") {
    e.preventDefault();
    prev();
  } else if (e.key === "ArrowRight") {
    e.preventDefault();
    next();
  }
}

/** 保存进度；scrollPercent 由滚动位置计算。 */
async function persistProgress(scrollPercent: number) {
  const title = content.value?.title ?? chapters.value[index.value]?.title ?? "";
  await readerApi.saveProgress(boundBookId.value, index.value, title, 0, scrollPercent);
}

/** 滚动时记录百分比（节流由浏览器 rAF 自然合并）。 */
function onScroll(e: Event) {
  // 朗读期间进度由朗读器按「段」推进并落盘，这里让位，避免两处互相覆盖。
  if (readingThisBook.value) return;
  const el = e.target as HTMLElement;
  const max = el.scrollHeight - el.clientHeight;
  if (max <= 0) return;
  const pct = Math.min(100, Math.round((el.scrollTop / max) * 100));
  persistProgress(pct);
}

// ---------------- 朗读 ----------------

/** 正文容器与标题元素（朗读切段的输入）。 */
function contentEl(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".content") ?? null;
}
function titleEl(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".text h1") ?? null;
}

/**
 * 朗读会话：store 只跟这个接口打交道，DOM 细节全留在阅读器里。
 * M2 的 PDF 换成「页级」实现后，store 一行都不用改。
 */
const session: TtsSession = {
  get bookId() {
    return boundBookId.value;
  },
  get bookName() {
    return book.value?.name ?? "";
  },
  chapterTitle: (ch) => chapters.value[ch]?.title ?? "",
  extract: async (ch) => {
    if (ch !== index.value) {
      const ok = await loadChapter(ch);
      if (!ok) return [];
    }
    await nextTick();
    const root = contentEl();
    const title = content.value?.title ?? chapters.value[ch]?.title ?? "";
    // 阅读器还挂着：直接在活 DOM 上切段，段落能带 el，高亮才生效。
    if (root) return domSegment(root, { chapter: ch, title: titleEl() });
    // 已经离开阅读器（组件卸载）：用同一份 HTML 离线切段，接着往下读。
    return segmentHTML(content.value?.html ?? "", { chapter: ch, title });
  },
  advance: async (i) => {
    // 后端给的 nextIndex 最权威（有的书章节不连续），退回 +1。
    const ni = content.value?.nextIndex ?? -1;
    const next = ni >= 0 ? ni : i + 1 < chapters.value.length ? i + 1 : -1;
    if (next < 0) return null;
    const ok = await loadChapter(next);
    return ok ? next : null;
  },
  save: (ch, _segIndex, ratio) => {
    const title = chapters.value[ch]?.title ?? "";
    void readerApi.saveProgress(
      boundBookId.value,
      ch,
      title,
      0,
      Math.round(ratio * 100),
    );
  },
};

/** 视口顶端的第一段：点「朗读」时从这里开始，而不是永远从章首。 */
function visibleSegmentIndex(): number {
  const root = contentEl();
  const sc = scroller();
  if (!root || !sc) return 0;
  const list = domSegment(root, { chapter: index.value, title: titleEl() });
  if (!list.length) return 0;
  const top = sc.getBoundingClientRect().top;
  for (let i = 0; i < list.length; i++) {
    const r = (list[i].el as HTMLElement).getBoundingClientRect();
    if (r.bottom > top + 4) return i;
  }
  return list.length - 1;
}

async function toggleRead() {
  if (!canRead.value) {
    ElMessage.warning(isComic.value ? "漫画没有文本，无法朗读" : "该格式暂不支持朗读");
    return;
  }
  if (readingThisBook.value) {
    tts.toggle();
    return;
  }
  await tts.start(session, {
    chapter: index.value,
    segIndex: visibleSegmentIndex(),
  });
}

/** 当前高亮元素（同一元素可能被多个段落共享，只需记住一个）。 */
let activeEl: HTMLElement | null = null;

function clearHighlight() {
  if (!activeEl) return;
  activeEl.classList.remove("tts-active");
  activeEl = null;
}

watch(
  () => tts.currentSegment,
  (seg) => {
    clearHighlight();
    if (!seg || tts.bookId !== boundBookId.value) return;
    const el = seg.el as HTMLElement | undefined;
    if (!el || !el.isConnected) return;
    const stage = stageRef.value;
    if (!stage || !stage.contains(el)) return;
    el.classList.add("tts-active");
    activeEl = el;
    // 只在段落跑出视口时才滚动，避免每段都把页面拽一下。
    const box = stage.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    if (r.top < box.top + 40 || r.bottom > box.bottom - 40) {
      // 用即时滚动而不是 smooth：连续朗读时段间只有几秒，平滑滚动会一直排不上队，
      // 观感是"高亮在跑、页面在追"，而且滚动过程中用户点击会点歪。
      el.scrollIntoView({ block: "center" });
    }
  },
);

watch(bookId, async () => {
  if (!bookId.value) return;
  clearHighlight();
  await loadMeta();
  await loadChapter(index.value);
  tts.attach(session);
});

onMounted(async () => {
  window.addEventListener("keydown", onKeydown);
  if (!bookId.value) return;
  await loadMeta();
  await loadChapter(index.value);
  // 绑定在正文渲染之后：store 若仍在读这本书，会重新切段以恢复高亮锚点。
  tts.attach(session);
});

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
  clearHighlight();
  // 解绑但不停播：文本类离开阅读器后可以继续听（这是需求，不是遗漏）。
  tts.detach(boundBookId.value);
});
</script>

<template>
  <div class="reader" v-loading="loading">
    <header class="bar">
      <el-button link @click="goBack">← 返回</el-button>
      <span class="title">{{ book?.name }}</span>
      <span class="chapter">{{ content?.title }}</span>
      <div class="spacer" />
      <el-tooltip content="复制书籍地址" placement="bottom">
        <button class="icon-btn" :disabled="!book" @click="copyBookURL">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <rect x="9" y="9" width="11" height="11" rx="2" />
            <path d="M5 15V6a2 2 0 0 1 2-2h9" />
          </svg>
        </button>
      </el-tooltip>
      <el-button link class="read-btn" :disabled="!canRead" @click="toggleRead">
        {{ readLabel }}
      </el-button>
      <el-dropdown trigger="click" @command="onCacheCommand">
        <el-button link class="cache-btn" :disabled="!canCache">
          {{ cacheLabel }}
        </el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="chapter">缓存本章</el-dropdown-item>
            <el-dropdown-item command="remaining">缓存剩余章节</el-dropdown-item>
            <el-dropdown-item command="all">缓存整本</el-dropdown-item>
            <el-dropdown-item command="manage" divided>管理缓存…</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
      <el-button link @click="tocVisible = !tocVisible">目录</el-button>
    </header>

    <div class="stage" ref="stageRef" @click="onStageClick">
      <!-- 目录抽屉 -->
      <aside v-show="tocVisible" class="toc">
        <div
          v-for="c in chapters"
          :key="c.index"
          class="toc-item"
          :class="{ active: c.index === index }"
          @click="userLoadChapter(c.index)"
        >
          <span class="toc-title">{{ c.title }}</span>
          <span
            v-if="cachedIndexes.has(c.index)"
            class="toc-cached"
            title="已缓存，可离线阅读"
            >●</span
          >
        </div>
      </aside>

      <!-- PDF：交给 WebView 内置 PDF 能力 -->
      <iframe v-if="isPdf" class="pdf" :src="pdfURL" />

      <!-- 漫画：图片流 -->
      <div v-else-if="isComic" class="comic" @scroll="onScroll">
        <img
          v-for="(src, i) in content?.images || []"
          :key="i"
          :src="comicImageURL(src, book?.origin)"
          loading="lazy"
        />
      </div>

      <!-- 文本类：正文 HTML -->
      <article
        v-else
        class="text"
        :style="{ fontSize: fontSize + 'px', lineHeight: lineHeight }"
        @scroll="onScroll"
      >
        <h1>{{ content?.title }}</h1>
        <!--
          正文来自书源或本地文件，属受控内容。
          后续可接入净化规则（替换/去广告）后再渲染，进一步降低风险。
        -->
        <div class="content" v-html="displayHTML" />
      </article>
    </div>

    <footer class="nav">
      <el-button :disabled="index <= 0" @click="prev">上一章</el-button>
      <span class="pos">
        {{ index + 1 }} / {{ content?.totalChapters || chapters.length }}
      </span>
      <el-button
        :disabled="!content || content.nextIndex < 0"
        @click="next"
      >
        下一章
      </el-button>
      <div class="spacer" />
      <span class="setting">字号</span>
      <el-slider
        v-model="fontSize"
        :min="14"
        :max="28"
        style="width: 120px"
      />
    </footer>
  </div>
</template>

<style scoped>
.reader {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.bar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 16px;
  background: #fff;
  border-bottom: 1px solid #e5e7eb;
}
.title {
  font-weight: 600;
}
.chapter {
  font-size: 12px;
  color: #6b7280;
}
.spacer {
  flex: 1;
}
.icon-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
  width: 28px;
  height: 28px;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: transparent;
  cursor: pointer;
}
.icon-btn:hover:not(:disabled) {
  background: rgba(0, 0, 0, 0.06);
}
.icon-btn:disabled {
  cursor: default;
  opacity: 0.4;
}
.icon-btn svg {
  width: 17px;
  height: 17px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.7);
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.stage {
  flex: 1;
  display: flex;
  min-height: 0;
}
.toc {
  width: 240px;
  flex: none;
  overflow: auto;
  background: #fff;
  border-right: 1px solid #e5e7eb;
  padding: 8px 0;
}
.toc-item {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 7px 14px;
  font-size: 13px;
  cursor: pointer;
  color: #374151;
}
.toc-title {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.toc-cached {
  flex: none;
  font-size: 8px;
  color: #16a34a;
}
.toc-item:hover {
  background: #f3f4f6;
}
.toc-item.active {
  color: #4338ca;
  font-weight: 600;
  background: #eef2ff;
}
.pdf {
  flex: 1;
  border: none;
}
.comic {
  flex: 1;
  overflow: auto;
  background: #1f2328;
}
.comic img {
  display: block;
  width: 100%;
}
.text {
  flex: 1;
  overflow: auto;
  padding: 32px 16px 64px;
  background: #fffdf7;
}
.text h1 {
  font-size: 1.4em;
  margin: 0 0 20px;
}
.content {
  max-width: 760px;
  margin: 0 auto;
}
.content :deep(p) {
  margin: 0 0 1em;
  text-indent: 2em;
}
.content :deep(img) {
  max-width: 100%;
}
/*
 * 正在朗读的段落。用 box-decoration-break 让跨行的底色连成一片，
 * 否则多行段落会显示成一截一截的。
 */
.content :deep(.tts-active),
.content :deep(.tts-seg.tts-active) {
  background: rgba(99, 102, 241, 0.16);
  border-radius: 3px;
  box-decoration-break: clone;
  -webkit-box-decoration-break: clone;
  transition: background 0.2s ease;
}
.nav {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 8px 16px;
  background: #fff;
  border-top: 1px solid #e5e7eb;
}
.pos {
  font-size: 13px;
  color: #6b7280;
}
.setting {
  font-size: 13px;
  color: #6b7280;
}
</style>
