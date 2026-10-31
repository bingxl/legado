<script setup lang="ts">
/**
 * 书籍详情页。
 *
 * 入口有两个：发现/搜索列表点击书籍行（后端会先把它加入书架，再带着 id 进来），
 * 以及书架里已有的书。整页只依赖 `bookshelfApi.getBook` + `readerApi.getChapters`，
 * 不直接访问绑定层（ARCHITECTURE.md R4）。
 *
 * 「继续阅读」按后端记录的进度定位章节；点目录里的任意章节则从该章开始读。
 */
import { computed, onMounted, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { ElMessage } from "element-plus";

import { bookshelfApi } from "@/api/bookshelf";
import { readerApi } from "@/api/reader";
import { CacheScope, cacheApi } from "@/api/cache";
import { jobPercent, useCacheStore } from "@/stores/cache";
import AIPanel from "@/components/AIPanel.vue";
import { copyText } from "@/utils/clipboard";
import { formatBytes } from "@/utils/format";
import { coverURL } from "@/utils/media";
import type { BookDetail, CacheBookStatus, ChapterItem } from "@/types";
import type { CacheScopeValue } from "@/api/cache";

const route = useRoute();
const router = useRouter();
const cache = useCacheStore();

const bookId = computed(() => Number(route.params.id || 0));
const book = ref<BookDetail | null>(null);
const chapters = ref<ChapterItem[]>([]);
const loading = ref(false);
const introOpen = ref(false);
const coverBroken = ref(false);
/** 目录一次最多渲染多少条：几千章的书全量挂 DOM 会明显卡顿。 */
const chapterLimit = ref(300);

/** 详情页的两个 Tab：目录与 AI 总结（移动端同样用这一对）。 */
const activeTab = ref<"toc" | "ai">("toc");

/** 缓存状态与对话框。 */
const cacheDialog = ref(false);
const cacheStatus = ref<CacheBookStatus | null>(null);
const cacheScope = ref<CacheScopeValue>(CacheScope.Remaining);

/** 本地书读的就是本地文件，缓存没有意义。 */
const canCache = computed(() => !!book.value && book.value.kind !== "local");
const cacheJob = computed(() => cache.jobOf(bookId.value));
const cacheRunning = computed(() => cacheJob.value?.state === "running");

const shownChapters = computed(() => chapters.value.slice(0, chapterLimit.value));
const hasMoreChapters = computed(() => chapters.value.length > chapterLimit.value);

/** 后端记录的章节序号；-1 表示没读过。 */
const progressIndex = computed(() => {
  const i = book.value?.durChapterIndex ?? -1;
  return i >= 0 ? i : 0;
});
const hasProgress = computed(() => (book.value?.percent ?? 0) > 0);
const readLabel = computed(() => (hasProgress.value ? "继续阅读" : "开始阅读"));
const percent = computed(() => book.value?.percent ?? 0);

async function load() {
  if (!bookId.value) return;
  loading.value = true;
  coverBroken.value = false;
  try {
    book.value = await bookshelfApi.getBook(bookId.value);
    chapters.value = (await readerApi.getChapters(bookId.value)) ?? [];
    await loadCacheStatus();
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

/** 读取缓存概况；失败不影响详情页主体内容。 */
async function loadCacheStatus() {
  if (!bookId.value) return;
  try {
    cacheStatus.value = await cacheApi.status(bookId.value);
  } catch {
    cacheStatus.value = null;
  }
}

/** 打开缓存对话框：默认「缓存剩余」，一本书读到哪就缓存到哪。 */
async function openCacheDialog() {
  cacheDialog.value = true;
  cacheScope.value =
    (cacheStatus.value?.cachedChapters ?? 0) > 0
      ? CacheScope.Missing
      : CacheScope.Remaining;
  await loadCacheStatus();
}

async function startCache() {
  try {
    await cache.start(bookId.value, cacheScope.value);
    ElMessage.success("已开始缓存，可在「缓存」页查看进度");
    cacheDialog.value = false;
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function cancelCache() {
  try {
    await cache.cancel(bookId.value);
    ElMessage.info("已取消缓存");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 任务结束后刷新一次概况，让「已缓存 N 章」立刻更新。 */
watch(
  () => cacheJob.value?.state,
  async (state, prev) => {
    if (prev === "running" && state && state !== "running") {
      await loadCacheStatus();
    }
  },
);

/** 进入阅读器，index 指定从哪一章开始（阅读器读 query.index）。 */
function openReader(index: number) {
  router.push({
    name: "reader",
    params: { id: String(bookId.value) },
    query: { index: String(Math.max(0, index)) },
  });
}

function back() {
  // 从发现/搜索直接进来时历史里有上一页；刷新后直接打开则退回书架。
  if (window.history.length > 1) router.back();
  else router.push("/");
}

/** 复制书籍地址。网络书是详情页 URL，本地书是文件路径。 */
async function copyBookURL() {
  const url = book.value?.bookUrl;
  if (!url) {
    ElMessage.warning("这本书没有可复制的地址");
    return;
  }
  if (await copyText(url)) ElMessage.success("已复制书籍地址");
  else ElMessage.error("复制失败，请手动复制");
}

watch(bookId, load);
onMounted(load);
</script>

<template>
  <div class="detail" v-loading="loading">
    <header class="bar">
      <button class="back" title="返回" @click="back">
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M15 5l-7 7 7 7" />
        </svg>
      </button>
      <span class="bar-title">{{ book?.name || "书籍详情" }}</span>
      <div class="bar-fill" />
      <button
        class="icon-btn"
        :disabled="!book"
        title="复制书籍地址"
        @click="copyBookURL"
      >
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <rect x="9" y="9" width="11" height="11" rx="2" />
          <path d="M5 15V6a2 2 0 0 1 2-2h9" />
        </svg>
      </button>
      <el-button
        type="primary"
        size="small"
        :disabled="!book"
        @click="openReader(progressIndex)"
      >
        {{ readLabel }}
      </el-button>
    </header>

    <div v-if="book" class="scroll">
      <div class="inner">
        <section class="hero">
          <div class="cover">
            <img
              v-if="book.cover && !coverBroken"
              :src="coverURL(book.cover)"
              :alt="book.name"
              @error="coverBroken = true"
            />
            <span v-else class="cover-fallback">{{ book.name.slice(0, 1) }}</span>
          </div>

          <div class="hero-main">
            <h1 class="name">{{ book.name }}</h1>
            <div class="author">{{ book.author || "佚名" }}</div>
            <div class="labels">
              <span v-if="book.kind" class="label">{{ book.kind }}</span>
              <span v-if="book.formatLabel" class="label">{{ book.formatLabel }}</span>
              <span v-if="book.totalChapters > 0" class="label">
                {{ book.totalChapters }} 章
              </span>
              <span
                v-if="(cacheStatus?.cachedChapters ?? 0) > 0"
                class="label cached"
              >
                已缓存 {{ cacheStatus?.cachedChapters }} 章
              </span>
            </div>
            <div v-if="book.lastChapter" class="line">
              最新：{{ book.lastChapter }}
            </div>
            <div v-if="hasProgress" class="progress">
              <el-progress :percentage="percent" :stroke-width="5" :show-text="false" />
              <span class="progress-text">
                读至 {{ book.durChapterTitle || `第 ${progressIndex + 1} 章` }} · {{ percent }}%
              </span>
            </div>
            <div class="hero-actions">
              <el-button type="primary" @click="openReader(progressIndex)">
                {{ readLabel }}
              </el-button>
              <el-button
                v-if="chapters.length"
                @click="openReader(0)"
              >从第一章开始</el-button>
              <el-button v-if="canCache" @click="openCacheDialog">
                <template v-if="cacheRunning">
                  缓存中 {{ jobPercent(cacheJob) }}%
                </template>
                <template v-else>缓存</template>
              </el-button>
            </div>
          </div>
        </section>

        <section v-if="book.intro" class="block">
          <h2 class="block-title">简介</h2>
          <p class="intro" :class="{ open: introOpen }">{{ book.intro }}</p>
          <button class="link" @click="introOpen = !introOpen">
            {{ introOpen ? "收起" : "展开全部" }}
          </button>
        </section>

        <section class="block">
          <el-tabs v-model="activeTab" class="detail-tabs">
            <el-tab-pane name="toc">
              <template #label>
                目录
                <span class="muted">{{ chapters.length }} 章</span>
              </template>

              <p v-if="!chapters.length" class="empty">这本书还没有目录</p>

              <ol v-else class="toc">
                <li
                  v-for="c in shownChapters"
                  :key="c.index"
                  class="toc-item"
                  :class="{
                    active: hasProgress && c.index === progressIndex,
                    volume: c.isVolume,
                  }"
                  @click="openReader(c.index)"
                >
                  <span class="toc-title">{{ c.title || `第 ${c.index + 1} 章` }}</span>
                  <span v-if="hasProgress && c.index === progressIndex" class="toc-tag">
                    上次读到
                  </span>
                </li>
              </ol>

              <div v-if="hasMoreChapters" class="more">
                <el-button size="small" @click="chapterLimit += 300">
                  显示更多（还有 {{ chapters.length - chapterLimit }} 章）
                </el-button>
              </div>
            </el-tab-pane>

            <el-tab-pane name="ai" label="AI 总结">
              <AIPanel
                :book-id="bookId"
                :chapters="chapters"
                :read-index="progressIndex"
                :started="hasProgress"
                :active="activeTab === 'ai'"
              />
            </el-tab-pane>
          </el-tabs>
        </section>
      </div>
    </div>

    <!-- 缓存对话框 -->
    <el-dialog
      v-model="cacheDialog"
      :title="`缓存《${book?.name || ''}》`"
      width="420px"
    >
      <div class="cache-info">
        <span>
          已缓存 {{ cacheStatus?.cachedChapters ?? 0 }}
          <template v-if="cacheStatus?.totalChapters">
            / {{ cacheStatus.totalChapters }}
          </template>
          章 · {{ formatBytes(cacheStatus?.size ?? 0) }}
        </span>
      </div>

      <el-radio-group v-model="cacheScope" :disabled="cacheRunning">
        <el-radio :value="CacheScope.Remaining">从阅读位置缓存到结尾</el-radio>
        <el-radio :value="CacheScope.All">缓存整本</el-radio>
        <el-radio :value="CacheScope.Missing">只补缺失章节</el-radio>
      </el-radio-group>

      <div v-if="cacheRunning" class="cache-progress">
        <el-progress
          :percentage="jobPercent(cacheJob)"
          :stroke-width="6"
        />
        <div class="cache-current">{{ cacheJob?.message }}</div>
      </div>

      <template #footer>
        <el-button @click="cacheDialog = false">关闭</el-button>
        <el-button v-if="cacheRunning" type="danger" plain @click="cancelCache">
          取消缓存
        </el-button>
        <el-button v-else type="primary" @click="startCache">开始缓存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.detail {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  background: #fff;
}
.bar {
  display: flex;
  align-items: center;
  gap: 8px;
  flex: none;
  height: 56px;
  padding: 0 16px;
  border-bottom: 1px solid #eef0f3;
}
.bar-title {
  font-size: 16px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 420px;
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
  margin-left: -6px;
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
  stroke: rgba(0, 0, 0, 0.75);
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.icon-btn {
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
.icon-btn:hover:not(:disabled) {
  background: rgba(0, 0, 0, 0.06);
}
.icon-btn:disabled {
  cursor: default;
  opacity: 0.4;
}
.icon-btn svg {
  width: 18px;
  height: 18px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.7);
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.scroll {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}
.inner {
  max-width: 960px;
  margin: 0 auto;
  padding: 20px 24px 32px;
}

/* ---- 头部信息 ---- */
.hero {
  display: flex;
  gap: 20px;
}
.cover {
  flex: none;
  width: 150px;
  height: 206px;
  border-radius: 6px;
  overflow: hidden;
  background: #f2f3f5;
  box-shadow: 0 2px 10px rgba(0, 0, 0, 0.08);
}
.cover img {
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
  font-size: 44px;
  color: rgba(0, 0, 0, 0.22);
}
.hero-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.name {
  margin: 0;
  font-size: 22px;
  line-height: 1.35;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
}
.author {
  font-size: 13px;
  color: rgba(0, 0, 0, 0.6);
}
.labels {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
}
.label.cached {
  background: #e8f5e9;
  color: #2e7d32;
}
.label {
  padding: 1px 8px;
  border-radius: 10px;
  background: rgba(0, 0, 0, 0.06);
  font-size: 12px;
  line-height: 18px;
  color: rgba(0, 0, 0, 0.62);
}
.line {
  font-size: 12px;
  color: rgba(0, 0, 0, 0.55);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.progress {
  display: flex;
  align-items: center;
  gap: 10px;
  max-width: 420px;
}
.progress :deep(.el-progress) {
  flex: 1;
}
.progress-text {
  flex: none;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.5);
}
.hero-actions {
  margin-top: auto;
  display: flex;
  gap: 8px;
}

/* ---- 区块 ---- */
.block {
  margin-top: 28px;
}
.block-title {
  display: flex;
  align-items: baseline;
  gap: 8px;
  margin: 0 0 10px;
  font-size: 15px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
}
.muted {
  font-size: 12px;
  font-weight: 400;
  color: rgba(0, 0, 0, 0.45);
}
.intro {
  margin: 0;
  font-size: 13px;
  line-height: 1.9;
  color: rgba(0, 0, 0, 0.68);
  white-space: pre-wrap;
  display: -webkit-box;
  -webkit-line-clamp: 4;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
.intro.open {
  -webkit-line-clamp: unset;
  display: block;
}
.link {
  margin-top: 6px;
  padding: 0;
  border: none;
  background: transparent;
  font-size: 12px;
  color: #1a73e8;
  cursor: pointer;
}

/* ---- 目录 ---- */
.toc {
  list-style: none;
  margin: 0;
  padding: 0;
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
  gap: 2px 16px;
}
.toc-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 10px;
  border-radius: 6px;
  font-size: 13px;
  color: rgba(0, 0, 0, 0.75);
  cursor: pointer;
}
.toc-item:hover {
  background: rgba(0, 0, 0, 0.045);
}
.toc-item.active {
  color: #1a73e8;
  background: #eff6ff;
}
.toc-item.volume {
  font-weight: 600;
  color: rgba(0, 0, 0, 0.5);
}
.toc-title {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.toc-tag {
  flex: none;
  font-size: 11px;
  color: #1a73e8;
}
.more {
  margin-top: 12px;
  text-align: center;
}
.empty {
  margin: 0;
  padding: 24px 0;
  text-align: center;
  font-size: 13px;
  color: rgba(0, 0, 0, 0.42);
}

/* ---- 缓存对话框 ---- */
.cache-info {
  margin-bottom: 12px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.55);
}
.cache-progress {
  margin-top: 14px;
}
.cache-current {
  margin-top: 6px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.5);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>
