<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { sourceApi } from "@/api/source";
import { systemApi, rawFileURL } from "@/api/system";
import { onSourceCheckProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";
import { useSourcesStore } from "@/stores/sources";
import type { SourceView, SourceCheckResult } from "@/types";
import SourceLoginDialog from "@/components/SourceLoginDialog.vue";

// 列表数据与加载态都住在 sources store 里：启动时已预载，进 tab 不再重拉；
// 编辑/导入/删除后就地更新，只有手动刷新才整表重拉。
const store = useSourcesStore();
const keyword = ref("");
const checkProgress = ref<ProgressPayload | null>(null);
const router = useRouter();

// ── 编辑入口 ────────────────────────────────────────────────
// 编辑不再是弹窗：书源有 70 个字段，还要边改边调试，弹窗装不下。
// 跳转到独立的编辑页（布局参考 Legado 官方 Web 编辑器）。
function openCreate() {
  router.push("/sources/new");
}

function openEdit(s: SourceView) {
  router.push(`/sources/${s.id}/edit`);
}

/** 直接跳到编辑页的调试标签，省去「先进编辑、再点调试」两步。 */
function openDebug(s: SourceView) {
  router.push(`/sources/${s.id}/edit?tab=debug`);
}

// ── 登录 ────────────────────────────────────────────────────
// 登录做成独立对话框而不是编辑页里的一个 Tab：登录是「一次性动作」，
// 跑完要立刻看到结果（Cookie 掩码、脚本日志、检测结论），
// 埋在 70 个字段的表单里既难找也没法当场验证。
const loginDialog = ref(false);
const loginTarget = ref<SourceView | null>(null);

function openLogin(s: SourceView) {
  loginTarget.value = s;
  loginDialog.value = true;
}

async function remove(s: SourceView) {
  await sourceApi.delete(s.id);
  store.removeLocal(s.id);
  ElMessage.success("已删除");
}

async function toggle(s: SourceView, enabled: boolean) {
  await sourceApi.setEnabled(s.id, enabled);
  // 启用状态是本地就能算出的字段，就地更新避免整表重拉。
  store.upsert({ ...s, enabled });
}

// ── 导入导出 ────────────────────────────────────────────────
function onImportCommand(cmd: string) {
  if (cmd === "file") {
    void importSources();
  } else if (cmd === "url") {
    urlDialog.value = true;
  }
}

async function importSources() {
  const paths = await systemApi.openSourceFile();
  if (!paths || paths.length === 0) return;
  try {
    // 后端接受 JSON 文本，这里在前端读取文件内容。
    const text = await readTextFile(paths[0]);
    const res = await sourceApi.import(text, true);
    if (!res) return;
    ElMessage.success(
      `导入完成：新增 ${res.imported}，更新 ${res.updated}，失败 ${(res.failures ?? []).length}`,
    );
    await store.refresh();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 从 URL 导入 ────────────────────────────────────────────
// 与「订阅」的分工：这里导入一次就结束，不随远程变化；想长期跟随远程更新
// 应该去订阅页加一条。地址允许指向任意含多书源的 JSON（也兼容 Legado 备份文件）。
const urlDialog = ref(false);
const urlInput = ref("");
const urlOverwrite = ref(true);
const urlLoading = ref(false);

async function importFromUrl() {
  const url = urlInput.value.trim();
  if (!url) {
    ElMessage.warning("请填写书源地址");
    return;
  }
  urlLoading.value = true;
  try {
    const res = await sourceApi.importFromUrl(url, urlOverwrite.value);
    if (!res) return;
    ElMessage.success(
      `导入完成：新增 ${res.imported}，更新 ${res.updated}，失败 ${(res.failures ?? []).length}`,
    );
    urlDialog.value = false;
    urlInput.value = "";
    await store.refresh();
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    urlLoading.value = false;
  }
}

async function exportSources() {
  try {
    const json = await sourceApi.export([]);
    const dest = await systemApi.saveFile("导出书源", "bookSources.json");
    if (!dest) return;
    await systemApi.saveTextFile(dest, json);
    ElMessage.success(`已导出到 ${dest}`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 通过后端 /raw/ 路由读取本地文本文件内容。 */
async function readTextFile(absPath: string): Promise<string> {
  const resp = await fetch(rawFileURL(absPath));
  if (!resp.ok) throw new Error("无法读取文件");
  return resp.text();
}

// ── 校验 ────────────────────────────────────────────────────
const checkDialog = ref(false);
const checkResults = ref<SourceCheckResult[]>([]);

async function validate() {
  // 表格没有多选，校验的永远是「全部启用书源」。这一步可能跑几十秒到几分钟，
  // 不给确认就直接开跑，用户会以为卡死了。
  try {
    await ElMessageBox.confirm(
      `将校验全部 ${store.sources.length} 个书源，耗时可能较长，期间可以关闭进度条继续用其他功能。是否开始？`,
      "校验书源",
      { confirmButtonText: "开始校验", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return; // 用户取消
  }
  checkDialog.value = true;
  checkResults.value = [];
  try {
    checkResults.value = (await sourceApi.validate([])) ?? [];
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 列表渲染 ────────────────────────────────────────────────
// el-table 无虚拟化：上千行 × 5 列（每行还有开关和 4 个按钮）一次性
// 挂载会明显卡顿。渲染层做增量分页：首屏 PAGE_SIZE 行，表格滚动触底后
// 自动在底部追加下一页；搜索/删除仍作用于完整 filtered 数组。
// 配合后端 List 不传 Raw，进页已无感。
const PAGE_SIZE = 300;
const visibleCount = ref(PAGE_SIZE);
const tableRef = ref<{ $el?: HTMLElement } | null>(null);

const filtered = computed(() => {
  const k = keyword.value.trim().toLowerCase();
  if (!k) return store.sources;
  return store.sources.filter(
    (s) =>
      s.name.toLowerCase().includes(k) ||
      s.group.toLowerCase().includes(k) ||
      s.url.toLowerCase().includes(k),
  );
});

const visibleRows = computed(() => filtered.value.slice(0, visibleCount.value));

/** 表格内部的滚动容器（Element Plus 表格 body 包在 el-scrollbar 里）。 */
function scrollWrap(): HTMLElement | null {
  return tableRef.value?.$el?.querySelector<HTMLElement>(".el-scrollbar__wrap") ?? null;
}

// 触底追加下一页。只做数组切片，无异步，无需 loading/防抖；
// 100px 的提前量让连续滚动时不出现「到底才触发」的顿挫。
function onTableScroll() {
  const wrap = scrollWrap();
  if (!wrap) return;
  const nearBottom =
    wrap.scrollTop + wrap.clientHeight >= wrap.scrollHeight - 100;
  if (nearBottom && visibleCount.value < filtered.value.length) {
    visibleCount.value = Math.min(
      visibleCount.value + PAGE_SIZE,
      filtered.value.length,
    );
  }
}

// 关键词变了就回到第一页并滚回顶部：搜索的目的就是缩小范围。
watch(keyword, () => {
  visibleCount.value = PAGE_SIZE;
  const wrap = scrollWrap();
  if (wrap) wrap.scrollTop = 0;
});

onMounted(() => {
  // store 启动时已预载过：这里只在真没数据时拉一次，进 tab 不再白等。
  void store.ensureLoaded();
  onSourceCheckProgress((data) => {
    checkProgress.value = data;
  });
  scrollWrap()?.addEventListener("scroll", onTableScroll, { passive: true });
});

onBeforeUnmount(() => {
  scrollWrap()?.removeEventListener("scroll", onTableScroll);
});
</script>

<template>
  <div class="source-view">
    <header class="toolbar">
      <el-input
        v-model="keyword"
        placeholder="搜索书源"
        clearable
        style="width: 240px"
      />
      <div class="spacer" />
      <el-button @click="validate">校验</el-button>
      <el-button @click="exportSources">导出</el-button>
      <el-button :loading="store.loading" @click="store.refresh()">刷新</el-button>
      <el-dropdown trigger="click" @command="onImportCommand">
        <el-button>导入</el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="file">从文件导入</el-dropdown-item>
            <el-dropdown-item command="url">从 URL 导入</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
      <el-button type="primary" @click="openCreate">新建</el-button>
    </header>

    <div class="progress" v-if="checkProgress">
      校验中 {{ checkProgress.done }}/{{ checkProgress.total }} —
      {{ checkProgress.current }}
    </div>

    <div class="table-wrap">
      <el-table ref="tableRef" :data="visibleRows" v-loading="store.loading" size="small" height="100%">
        <el-table-column prop="name" label="名称" min-width="160" />
        <el-table-column prop="group" label="分组" width="120" />
        <el-table-column prop="url" label="地址" min-width="220" show-overflow-tooltip />
        <el-table-column label="启用" width="80">
          <template #default="{ row }">
            <el-switch
              :model-value="row.enabled"
              @change="(v: boolean) => toggle(row, v)"
            />
          </template>
        </el-table-column>
        <!-- 操作列不固定：fixed 列在窄窗口下反而压缩主内容区，且本页无横向滚动需求 -->
        <el-table-column label="操作" width="220">
          <template #default="{ row }">
            <el-button link type="primary" data-login-row="login" @click="openLogin(row)">
              登录
            </el-button>
            <el-button link type="primary" @click="openEdit(row)">编辑</el-button>
            <el-button link type="primary" @click="openDebug(row)">调试</el-button>
            <el-button link type="danger" @click="remove(row)">删除</el-button>
          </template>
        </el-table-column>
        <template #empty>
          <el-empty description="还没有书源，导入一份试试" />
        </template>
      </el-table>
    </div>
    <div v-if="filtered.length > PAGE_SIZE" class="table-foot">
      <template v-if="visibleRows.length < filtered.length">
        已显示 {{ visibleRows.length }} / 共 {{ filtered.length }} 条，
        滑到底部自动加载下一页（也可用上方搜索缩小范围）
      </template>
      <template v-else>已显示全部 {{ filtered.length }} 条</template>
    </div>

    <SourceLoginDialog
      v-model="loginDialog"
      :source-id="loginTarget?.id ?? 0"
      :source-name="loginTarget?.name"
      @changed="store.refresh()"
    />

    <!-- 从 URL 导入 -->
    <el-dialog v-model="urlDialog" title="从 URL 导入书源" width="560">
      <el-input
        v-model="urlInput"
        placeholder="https://example.com/bookSources.json"
        clearable
        @keyup.enter="importFromUrl"
      />
      <p class="hint">
        地址指向一份书源 JSON 文件，可包含多个书源；也兼容 Legado 备份文件（含 data 字段）。
      </p>
      <el-checkbox v-model="urlOverwrite">
        覆盖相同 bookSourceUrl 的书源
      </el-checkbox>
      <p class="hint">
        只导入这一次，之后不跟随远程变化。想让书源随远程更新，请到「订阅」里加一条。
      </p>
      <template #footer>
        <el-button @click="urlDialog = false">取消</el-button>
        <el-button type="primary" :loading="urlLoading" @click="importFromUrl">
          导入
        </el-button>
      </template>
    </el-dialog>

    <!-- 校验结果 -->
    <el-dialog v-model="checkDialog" title="书源校验结果" width="680">
      <div v-if="checkResults.length === 0" class="checking">正在校验…</div>
      <div v-for="r in checkResults" :key="r.sourceId" class="check-item">
        <div class="check-title">
          <span :class="r.ok ? 'ok' : 'bad'">{{ r.ok ? "通过" : "有问题" }}</span>
          {{ r.sourceName }}
        </div>
        <ul>
          <li v-for="(i, idx) in r.issues" :key="idx">
            [{{ i.level }}] {{ i.field }} {{ i.message }}
          </li>
        </ul>
      </div>
      <template #footer>
        <el-button @click="checkDialog = false">关闭</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.source-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  padding: 0 0 12px;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 16px;
}
.spacer {
  flex: 1;
}
.progress {
  padding: 6px 16px;
  font-size: 13px;
  color: #9a3412;
  background: #fff7ed;
}
.table-wrap {
  flex: 1;
  min-height: 0;
  display: flex;
}
.table-foot {
  padding: 4px 16px 0;
  font-size: 12px;
  color: #6b7280;
}
.check-item {
  margin-bottom: 12px;
}
.check-title {
  font-weight: 600;
  margin-bottom: 4px;
}
.ok {
  color: #16a34a;
}
.bad {
  color: #dc2626;
}
.check-item ul {
  margin: 0;
  padding-left: 18px;
  font-size: 12px;
  color: #4b5563;
}
.checking {
  color: #6b7280;
  font-size: 13px;
}
.hint {
  margin: 8px 0 0;
  font-size: 12px;
  line-height: 1.5;
  color: #6b7280;
}
.hint + .el-checkbox {
  margin-top: 12px;
}
</style>
