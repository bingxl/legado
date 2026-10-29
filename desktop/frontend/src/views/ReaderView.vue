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
import { rawFileURL } from "@/api/system";
import { copyText } from "@/utils/clipboard";
import { comicImageURL } from "@/utils/media";
import type { BookDetail, ChapterContent, ChapterItem } from "@/types";

const route = useRoute();
const router = useRouter();

const bookId = computed(() => Number(route.params.id || 0));
const book = ref<BookDetail | null>(null);
const chapters = ref<ChapterItem[]>([]);
const content = ref<ChapterContent | null>(null);
const index = ref(0);
const loading = ref(false);
const tocVisible = ref(false);
const stageRef = ref<HTMLElement | null>(null);

/** 正文/漫画的滚动容器（二者互斥渲染，PDF 由 iframe 自己管）。 */
function scroller(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".text, .comic") ?? null;
}

// 阅读偏好
const fontSize = ref(17);
const lineHeight = ref(1.9);

const isPdf = computed(() => book.value?.format === "pdf");
/** 漫画：本地漫画文件，或网络漫画源的章节图片流（后端已把 <img> 抽成 images）。 */
const isComic = computed(
  () => book.value?.format === "comic" || (content.value?.images?.length ?? 0) > 0,
);

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

/** PDF 直读地址：本地路径经后端 /raw/ 路由暴露。 */
const pdfURL = computed(() =>
  book.value ? rawFileURL(book.value.bookUrl) : "",
);

async function loadMeta() {
  book.value = await bookshelfApi.getBook(bookId.value);
  chapters.value = await readerApi.getChapters(bookId.value);
  const p = await readerApi.getProgress(bookId.value);
  // 详情页点某一章进来时带 ?index=N，优先于上次阅读进度。
  const want = Number(route.query.index);
  if (Number.isFinite(want) && want >= 0 && Math.trunc(want) < chapters.value.length) {
    index.value = Math.trunc(want);
    return;
  }
  index.value = p.chapterIndex >= 0 ? p.chapterIndex : 0;
}

/** 返回上一页（详情页或书架）；直接打开阅读器时退回书架。 */
function goBack() {
  if (window.history.length > 1) router.back();
  else router.push("/");
}

async function loadChapter(i: number) {
  loading.value = true;
  try {
    content.value = await readerApi.getContent(bookId.value, i);
    index.value = i;
    // 换章后必须回到顶部，否则新章节会继承上一章的滚动位置。
    await nextTick();
    const sc = scroller();
    if (sc) sc.scrollTop = 0;
    await persistProgress(0);
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

function prev() {
  if (loading.value) return;
  if (index.value > 0) loadChapter(index.value - 1);
}
function next() {
  if (loading.value) return;
  if (content.value && content.value.nextIndex >= 0) {
    loadChapter(content.value.nextIndex);
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
  await readerApi.saveProgress(bookId.value, index.value, title, 0, scrollPercent);
}

/** 滚动时记录百分比（节流由浏览器 rAF 自然合并）。 */
function onScroll(e: Event) {
  const el = e.target as HTMLElement;
  const max = el.scrollHeight - el.clientHeight;
  if (max <= 0) return;
  const pct = Math.min(100, Math.round((el.scrollTop / max) * 100));
  persistProgress(pct);
}

watch(bookId, async () => {
  if (!bookId.value) return;
  await loadMeta();
  await loadChapter(index.value);
});

onMounted(async () => {
  window.addEventListener("keydown", onKeydown);
  if (!bookId.value) return;
  await loadMeta();
  await loadChapter(index.value);
});

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
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
          @click="loadChapter(c.index)"
        >
          {{ c.title }}
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
        <div class="content" v-html="content?.html || ''" />
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
  padding: 7px 14px;
  font-size: 13px;
  cursor: pointer;
  color: #374151;
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
