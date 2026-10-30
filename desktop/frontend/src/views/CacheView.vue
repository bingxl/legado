<script setup lang="ts">
/**
 * 缓存管理页。
 *
 * 两件事：
 *  1. 看：哪些书缓存了多少章、占多大、最近一次缓存是什么时候；
 *  2. 删：按章删、按书删、全清。
 *
 * 缓存本身是手动触发的（阅读器/详情页的「缓存」按钮），本页只负责
 * 补充缓存（补缺失/继续缓存剩余）和清理。
 */
import { computed, onMounted, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import { CacheScope, cacheApi } from "@/api/cache";
import { jobPercent, useCacheStore } from "@/stores/cache";
import { formatBytes, formatDateTime } from "@/utils/format";
import { coverURL } from "@/utils/media";
import type { CacheBookView, CachedChapterView, CacheStats } from "@/types";

const cache = useCacheStore();

const stats = ref<CacheStats>({ books: 0, chapters: 0, size: 0, running: 0 });
const books = ref<CacheBookView[]>([]);
const loading = ref(false);

/** 当前展开章节明细的书。 */
const expandedId = ref(0);
const chapters = ref<CachedChapterView[]>([]);
const chaptersLoading = ref(false);
const selected = ref<CachedChapterView[]>([]);

const hasData = computed(() => books.value.length > 0);

async function load() {
  loading.value = true;
  try {
    const [s, list] = await Promise.all([cacheApi.stats(), cacheApi.books()]);
    stats.value = s;
    books.value = list;
    // 展开的书被删空后收起，避免留下一个空面板。
    if (expandedId.value && !list.some((b) => b.bookId === expandedId.value)) {
      expandedId.value = 0;
      chapters.value = [];
    }
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

async function toggleChapters(bookId: number) {
  if (expandedId.value === bookId) {
    expandedId.value = 0;
    chapters.value = [];
    return;
  }
  expandedId.value = bookId;
  await loadChapters(bookId);
}

async function loadChapters(bookId: number) {
  chaptersLoading.value = true;
  try {
    chapters.value = await cacheApi.chapters(bookId);
    selected.value = [];
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    chaptersLoading.value = false;
  }
}

/** 补充缓存：已有缓存时只补缺失，没有缓存时整本。 */
async function fill(book: CacheBookView) {
  const scope = book.cachedChapters > 0 ? CacheScope.Missing : CacheScope.All;
  try {
    await cache.start(book.bookId, scope);
    ElMessage.success(`已开始缓存《${book.name}》`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 从当前阅读进度往后缓存。 */
async function fillRemaining(book: CacheBookView) {
  try {
    await cache.start(book.bookId, CacheScope.Remaining);
    ElMessage.success(`已开始缓存《${book.name}》剩余章节`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function cancelJob(bookId: number) {
  try {
    await cache.cancel(bookId);
    ElMessage.info("已取消缓存");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function removeBook(book: CacheBookView) {
  try {
    await ElMessageBox.confirm(
      `确定清空《${book.name}》的 ${book.cachedChapters} 章缓存（${formatBytes(book.size)}）吗？`,
      "清空该书的缓存",
      { type: "warning", confirmButtonText: "清空", cancelButtonText: "取消" },
    );
  } catch {
    return; // 用户取消
  }
  try {
    await cacheApi.purgeBook(book.bookId);
    ElMessage.success("缓存已清空");
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function removeSelected() {
  const id = expandedId.value;
  if (!id || !selected.value.length) return;
  try {
    await cacheApi.deleteChapters(
      id,
      selected.value.map((c) => c.index),
    );
    ElMessage.success("已删除所选缓存");
    await Promise.all([load(), loadChapters(id)]);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function removeChapter(index: number) {
  const id = expandedId.value;
  if (!id) return;
  try {
    await cacheApi.deleteChapters(id, [index]);
    ElMessage.success("已删除该章缓存");
    await Promise.all([load(), loadChapters(id)]);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function clearAll() {
  try {
    await ElMessageBox.confirm(
      `确定清空全部缓存吗？共 ${stats.value.chapters} 章、${formatBytes(stats.value.size)}，删除后需要重新缓存才能离线阅读。`,
      "清空全部缓存",
      { type: "warning", confirmButtonText: "全部清空", cancelButtonText: "取消" },
    );
  } catch {
    return;
  }
  try {
    await cacheApi.clear();
    ElMessage.success("全部缓存已清空");
    expandedId.value = 0;
    chapters.value = [];
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// 任务全部结束后刷新一次，让章数与占用立刻反映出来。
watch(
  () => cache.runningJobs.length,
  async (now, before) => {
    if (before > 0 && now === 0) await load();
  },
);

onMounted(async () => {
  await Promise.all([load(), cache.refreshJobs()]);
});
</script>

<template>
  <div class="cache-view" v-loading="loading">
    <header class="head">
      <div>
        <h1 class="title">缓存管理</h1>
        <p class="sub">
          <template v-if="stats.chapters > 0">
            共 {{ stats.books }} 本 · {{ stats.chapters }} 章 ·
            {{ formatBytes(stats.size) }}
          </template>
          <template v-else>还没有缓存任何内容</template>
        </p>
      </div>
      <div class="head-actions">
        <el-button size="small" @click="load">刷新</el-button>
        <el-button
          size="small"
          type="danger"
          plain
          :disabled="stats.chapters === 0"
          @click="clearAll"
        >
          清空全部
        </el-button>
      </div>
    </header>

    <!-- 运行中的任务 -->
    <section v-if="cache.runningJobs.length" class="jobs">
      <div v-for="job in cache.runningJobs" :key="job.bookId" class="job">
        <div class="job-line">
          <span class="job-name">《{{ job.bookName }}》缓存中</span>
          <span class="job-count">
            {{ job.done + job.failed }} / {{ job.total }}
            <template v-if="job.failed"> · {{ job.failed }} 章失败</template>
          </span>
          <button class="link" @click="cancelJob(job.bookId)">取消</button>
        </div>
        <el-progress
          :percentage="jobPercent(job)"
          :stroke-width="4"
          :show-text="false"
        />
        <div class="job-current">{{ job.message }}</div>
      </div>
    </section>

    <p v-if="!hasData" class="empty">
      还没有缓存内容。在书籍详情页或阅读器里点「缓存」，即可把整本或指定章节存到本地。
    </p>

    <!-- 按书列表 -->
    <section v-else class="list">
      <article v-for="book in books" :key="book.bookId" class="row">
        <div class="row-main">
          <img
            v-if="book.cover"
            class="cover"
            :src="coverURL(book.cover)"
            :alt="book.name"
          />
          <span v-else class="cover cover-fallback">
            {{ book.name.slice(0, 1) }}
          </span>

          <div class="meta">
            <div class="name">{{ book.name }}</div>
            <div class="line">
              <span v-if="book.author">{{ book.author }} · </span>
              <span>{{ book.formatLabel }}</span>
              <span>
                · 已缓存 {{ book.cachedChapters }}
                <template v-if="book.totalChapters > 0">
                  / {{ book.totalChapters }}
                </template>
                章
              </span>
              <span v-if="book.updatedAt">
                · {{ formatDateTime(book.updatedAt) }}
              </span>
            </div>
            <div v-if="cache.jobOf(book.bookId)?.state === 'running'" class="line warn">
              缓存中 {{ cache.jobOf(book.bookId)?.message }}
            </div>
            <div
              v-else-if="cache.jobOf(book.bookId)?.state === 'done'"
              class="line ok"
            >
              上次缓存已完成
            </div>
          </div>

          <div class="size">{{ formatBytes(book.size) }}</div>

          <div class="actions">
            <el-button
              size="small"
              :disabled="cache.isRunning(book.bookId)"
              @click="fill(book)"
            >
              {{ book.cachedChapters > 0 ? "补缺失" : "缓存整本" }}
            </el-button>
            <el-button
              size="small"
              :disabled="cache.isRunning(book.bookId)"
              @click="fillRemaining(book)"
            >
              缓存剩余
            </el-button>
            <el-button size="small" @click="toggleChapters(book.bookId)">
              {{ expandedId === book.bookId ? "收起" : "章节明细" }}
            </el-button>
            <el-button size="small" type="danger" plain @click="removeBook(book)">
              删除
            </el-button>
          </div>
        </div>

        <!-- 章节明细 -->
        <div v-if="expandedId === book.bookId" class="detail" v-loading="chaptersLoading">
          <div class="detail-bar">
            <span class="detail-count">{{ chapters.length }} 章已缓存</span>
            <div class="spacer" />
            <el-button
              size="small"
              type="danger"
              plain
              :disabled="!selected.length"
              @click="removeSelected"
            >
              删除所选（{{ selected.length }}）
            </el-button>
          </div>
          <el-table
            :data="chapters"
            size="small"
            max-height="320"
            @selection-change="(rows: CachedChapterView[]) => (selected = rows)"
          >
            <el-table-column type="selection" width="42" />
            <el-table-column prop="index" label="#" width="64">
              <template #default="{ row }">{{ row.index + 1 }}</template>
            </el-table-column>
            <el-table-column prop="title" label="章节" min-width="220" />
            <el-table-column label="占用" width="100">
              <template #default="{ row }">{{ formatBytes(row.size) }}</template>
            </el-table-column>
            <el-table-column label="缓存时间" width="130">
              <template #default="{ row }">
                {{ formatDateTime(row.updatedAt) }}
              </template>
            </el-table-column>
            <el-table-column label="操作" width="80">
              <template #default="{ row }">
                <button class="link danger" @click="removeChapter(row.index)">
                  删除
                </button>
              </template>
            </el-table-column>
          </el-table>
        </div>
      </article>
    </section>
  </div>
</template>

<style scoped>
.cache-view {
  padding: 20px 24px 40px;
  overflow: auto;
}
.head {
  display: flex;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 16px;
}
.title {
  margin: 0 0 4px;
  font-size: 18px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
}
.sub {
  margin: 0;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.5);
}
.head-actions {
  margin-left: auto;
  display: flex;
  gap: 8px;
}

.jobs {
  display: flex;
  flex-direction: column;
  gap: 10px;
  margin-bottom: 16px;
}
.job {
  padding: 10px 14px;
  border: 1px solid #e0e7ff;
  border-radius: 8px;
  background: #f5f7ff;
}
.job-line {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 6px;
  font-size: 13px;
  color: #374151;
}
.job-name {
  font-weight: 600;
}
.job-count {
  color: #6b7280;
}
.job-line .link {
  margin-left: auto;
}
.job-current {
  margin-top: 6px;
  font-size: 12px;
  color: #6b7280;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.empty {
  padding: 60px 0;
  text-align: center;
  font-size: 13px;
  line-height: 1.9;
  color: rgba(0, 0, 0, 0.45);
}

.list {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.row {
  border: 1px solid #eef0f3;
  border-radius: 10px;
  background: #fff;
}
.row-main {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 12px 14px;
}
.cover {
  flex: none;
  width: 40px;
  height: 56px;
  border-radius: 4px;
  object-fit: cover;
  background: #f2f3f5;
}
.cover-fallback {
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 18px;
  color: rgba(0, 0, 0, 0.25);
}
.meta {
  flex: 1;
  min-width: 0;
}
.name {
  font-size: 14px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.line {
  margin-top: 3px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.5);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.line.warn {
  color: #b45309;
}
.line.ok {
  color: #15803d;
}
.size {
  flex: none;
  font-size: 13px;
  color: rgba(0, 0, 0, 0.6);
}
.actions {
  flex: none;
  display: flex;
  gap: 6px;
}

.detail {
  border-top: 1px dashed #eef0f3;
  padding: 8px 14px 12px;
}
.detail-bar {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 8px;
}
.detail-count {
  font-size: 12px;
  color: rgba(0, 0, 0, 0.5);
}
.spacer {
  flex: 1;
}
.link {
  padding: 0;
  border: none;
  background: transparent;
  font-size: 12px;
  color: #1a73e8;
  cursor: pointer;
}
.link.danger {
  color: #dc2626;
}
</style>
