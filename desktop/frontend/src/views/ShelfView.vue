<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { useBookshelfStore } from "@/stores/bookshelf";
import { libraryApi } from "@/api/library";
import { bookshelfApi } from "@/api/bookshelf";
import { systemApi } from "@/api/system";
import { coverURL } from "@/utils/media";
import type { BookBrief, ImportResult } from "@/types";

const router = useRouter();
const shelf = useBookshelfStore();

const importDialog = ref(false);
const importResult = ref<ImportResult | null>(null);
const groupDialog = ref(false);
const newGroupName = ref("");

/** 导入选中的分组（0 表示全部/未分组）。 */
const targetGroup = computed(() =>
  shelf.activeGroup === 0 ? 0 : shelf.activeGroup,
);

/** 导入结果里的失败清单（后端 nil slice 会被序列化成 null）。 */
const importFailures = computed(() => importResult.value?.failed ?? []);
const importOkCount = computed(() => importResult.value?.imported?.length ?? 0);

// 书架不在内存里做缓存：从发现/搜索页入架后切回来必须看到最新数据。
onMounted(() => shelf.refresh());

async function importBooks() {
  const paths = await systemApi.openBooks();
  if (!paths || paths.length === 0) return;
  try {
    const res = await libraryApi.importFiles(paths, targetGroup.value);
    importResult.value = res;
    importDialog.value = true;
    await shelf.refresh();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function importComicDir() {
  const dir = await systemApi.openDirectory("选择漫画目录");
  if (!dir) return;
  try {
    const res = await libraryApi.importFiles([dir], targetGroup.value);
    importResult.value = res;
    importDialog.value = true;
    await shelf.refresh();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function createGroup() {
  const name = newGroupName.value.trim();
  if (!name) {
    // 不能静默 return：弹窗不动、也没有提示，用户会以为按钮坏了。
    ElMessage.warning("请输入分组名称");
    return;
  }
  try {
    await bookshelfApi.createGroup(name);
  } catch (e) {
    ElMessage.error((e as Error).message);
    return;
  }
  newGroupName.value = "";
  groupDialog.value = false;
  await shelf.loadGroups();
  ElMessage.success("分组已创建");
}

async function exportBook(book: BookBrief) {
  try {
    const dest = await systemApi.saveFile(
      "导出书籍",
      `${book.name}.epub`,
    );
    if (!dest) return;
    const res = await libraryApi.exportBook(book.id, "epub", dest);
    if (!res) return;
    ElMessage.success(`已导出到 ${res.path}`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function removeBook(book: BookBrief) {
  try {
    await ElMessageBox.confirm(`确定从书架移除《${book.name}》？`, "提示", {
      type: "warning",
    });
  } catch {
    return; // 用户取消
  }
  await shelf.removeBook(book.id);
  ElMessage.success("已移除");
}

function openBook(book: BookBrief) {
  router.push({ name: "reader", params: { id: String(book.id) } });
}
</script>

<template>
  <div class="shelf">
    <header class="toolbar">
      <el-input
        v-model="shelf.keyword"
        placeholder="搜索书名或作者"
        clearable
        class="r-fit"
        style="--r-fit-w: 240px"
      />
      <div class="spacer" />
      <el-button @click="groupDialog = true">新建分组</el-button>
      <el-button @click="importComicDir">导入目录</el-button>
      <el-button type="primary" @click="importBooks">导入书籍</el-button>
    </header>

    <div class="body">
      <aside class="groups">
        <div
          class="group-item"
          :class="{ active: shelf.activeGroup === 0 }"
          @click="shelf.selectGroup(0)"
        >
          全部
        </div>
        <div
          v-for="g in shelf.groups"
          :key="g.id"
          class="group-item"
          :class="{ active: shelf.activeGroup === g.id }"
          @click="shelf.selectGroup(g.id)"
        >
          {{ g.name }}
        </div>
      </aside>

      <section class="grid-wrap" v-loading="shelf.loading">
        <el-empty
          v-if="shelf.visibleBooks.length === 0"
          description="书架还是空的，先导入一本书吧"
        />
        <div v-else class="grid">
          <article
            v-for="b in shelf.visibleBooks"
            :key="b.id"
            class="card"
            @click="openBook(b)"
          >
            <div class="cover">
              <img v-if="b.cover" :src="coverURL(b.cover)" :alt="b.name" />
              <div v-else class="cover-fallback">{{ b.formatLabel }}</div>
              <!-- 本地书源文件丢失：入口处就亮红牌，避免进了阅读器才见到报错 -->
              <span v-if="b.fileMissing" class="missing-badge">文件丢失</span>
            </div>
            <div class="meta">
              <div class="name" :title="b.name">{{ b.name }}</div>
              <div class="author">{{ b.author || "未知作者" }}</div>
              <el-progress
                :percentage="b.percent"
                :stroke-width="4"
                :show-text="false"
              />
              <div class="tags">
                <span class="tag">{{ b.formatLabel }}</span>
                <span v-if="b.durChapterTitle" class="read-to">
                  读至 {{ b.durChapterTitle }}
                </span>
              </div>
            </div>
            <div class="actions" @click.stop>
              <el-button size="small" text @click="exportBook(b)">导出</el-button>
              <el-button size="small" text type="danger" @click="removeBook(b)">
                移除
              </el-button>
            </div>
          </article>
        </div>
      </section>
    </div>

    <!-- 导入结果 -->
    <el-dialog v-model="importDialog" title="导入结果" width="520">
      <div v-if="importResult">
        <p>成功 {{ importOkCount }} 本，失败 {{ importFailures.length }} 个。</p>
        <ul v-if="importFailures.length" class="failures">
          <li v-for="(f, i) in importFailures" :key="i">
            {{ f.path }} — {{ f.reason }}
          </li>
        </ul>
      </div>
      <template #footer>
        <el-button type="primary" @click="importDialog = false">知道了</el-button>
      </template>
    </el-dialog>

    <!-- 新建分组 -->
    <el-dialog v-model="groupDialog" title="新建分组" width="400">
      <el-input v-model="newGroupName" placeholder="分组名称" />
      <template #footer>
        <el-button @click="groupDialog = false">取消</el-button>
        <el-button type="primary" @click="createGroup">创建</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.shelf {
  display: flex;
  flex-direction: column;
  height: 100%;
}
.toolbar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  background: #fff;
  border-bottom: 1px solid #e5e7eb;
}
.spacer {
  flex: 1;
}
.body {
  flex: 1;
  display: flex;
  min-height: 0;
  min-width: 0;
}
.groups {
  width: 140px;
  max-width: 100%;
  flex: none;
  padding: var(--r-pad-sm);
  border-right: 1px solid #e5e7eb;
  background: #fff;
  overflow: auto;
}
.group-item {
  padding: 8px 10px;
  border-radius: var(--r-radius-sm);
  cursor: pointer;
  font-size: 14px;
  color: #374151;
}
.group-item:hover {
  background: #f3f4f6;
}
.group-item.active {
  background: #eef2ff;
  color: #4338ca;
  font-weight: 600;
}
.grid-wrap {
  flex: 1;
  min-width: 0;
  padding: var(--r-pad);
  overflow: auto;
}
.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(min(100%, var(--r-card-min)), 1fr));
  gap: var(--r-gap);
  min-width: 0;
}
.card {
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius);
  overflow: hidden;
  cursor: pointer;
  transition: box-shadow 0.15s;
}
.card:hover {
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.08);
}
.cover {
  height: var(--r-cover-h);
  background: #f3f4f6;
  display: flex;
  align-items: center;
  justify-content: center;
  position: relative;
}
/* 本地书源文件丢失角标 */
.missing-badge {
  position: absolute;
  top: 8px;
  right: 8px;
  z-index: 1;
  padding: 2px 8px;
  border-radius: 4px;
  background: #fef0f0;
  color: #f56c6c;
  border: 1px solid #fde2e2;
  font-size: 12px;
  line-height: 18px;
}
.cover img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.cover-fallback {
  color: #9ca3af;
  font-size: 13px;
}
.meta {
  padding: 8px 10px;
}
.name {
  font-size: 14px;
  font-weight: 600;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.author {
  font-size: 12px;
  color: #6b7280;
  margin: 2px 0 6px;
}
.tags {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  margin-top: 6px;
  min-width: 0;
  font-size: 11px;
  color: #6b7280;
}
.tag {
  flex: none;
  background: #f3f4f6;
  padding: 1px 6px;
  border-radius: 4px;
}
.read-to {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.actions {
  display: flex;
  flex-wrap: wrap;
  justify-content: space-between;
  gap: var(--r-gap-sm);
  padding: 0 6px 6px;
}
.failures {
  max-height: min(200px, 90vh);
  overflow: auto;
  font-size: 12px;
  color: #b91c1c;
}

/* 平板/窄窗口：分组侧栏收成横向可滚动的 chip 条，主区独占一行（保留 DOM 与类名） */
@media (max-width: 1024px) {
  .body {
    flex-direction: column;
  }
  .groups {
    width: auto;
    max-width: 100%;
    flex: none;
    display: flex;
    flex-direction: row;
    gap: var(--r-gap-sm);
    padding: var(--r-pad-sm);
    border-right: none;
    border-bottom: 1px solid #e5e7eb;
    overflow-x: auto;
    overflow-y: hidden;
    -webkit-overflow-scrolling: touch;
  }
  .group-item {
    flex: none;
    white-space: nowrap;
  }
  .grid-wrap {
    min-height: 0;
  }
}
</style>
