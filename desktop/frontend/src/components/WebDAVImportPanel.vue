<script setup lang="ts">
/**
 * 从 WebDAV 选择书籍并导入。
 *
 * 三条设计约束（都来自实际会踩的坑）：
 * 1. 目录必须能进也能"选"——用户既想只导入一个文件，也想整目录导入；
 * 2. 进度不能只靠事件——打包后的 @wailsio/runtime 事件注册表与运行时的那份
 *    互不相通，这里额外用 1s 轮询 BookImportStatus 兜底；
 * 3. 下载与解析都在后端后台进行，切走页签再回来要能续上看进度，
 *    所以挂载时先读一次 bookImportStatus。
 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { webdavApi } from "@/api/webdav";
import { onWebDAVImportProgress } from "@/api/events";
import type { WebDAVImportProgressPayload } from "@/api/events";
import { formatBytes, formatDateTime } from "@/utils/format";
import type {
  ImportFailure,
  RemoteBookView,
  WebDAVEntryView,
  WebDAVImportJob,
} from "@/types";

const props = defineProps<{ configured: boolean }>();
const router = useRouter();

const curPath = ref("");
const entries = ref<WebDAVEntryView[]>([]);
const loading = ref(false);
const selection = ref<WebDAVEntryView[]>([]);
const scanning = ref(false);
const job = ref<WebDAVImportJob | null>(null);
const failures = ref<ImportFailure[]>([]);
const showFailures = ref(false);

/** 支持导入的扩展名，与后端 domain.ParseBookFormat 保持一致。 */
const BOOK_EXT = /\.(txt|epub|pdf|zip|cbz|cbr|rar|7z)$/i;

const atRoot = computed(() => curPath.value === "");
const crumbs = computed(() => {
  const out = [{ name: "根目录", path: "" }];
  let acc = "";
  for (const seg of curPath.value.split("/").filter(Boolean)) {
    acc = acc ? `${acc}/${seg}` : seg;
    out.push({ name: seg, path: acc });
  }
  return out;
});

const running = computed(() => job.value?.state === "running");
const percent = computed(() => {
  const j = job.value;
  if (!j || j.total <= 0) return 0;
  const n = j.done + j.failed;
  return Math.min(100, Math.round((n * 100) / j.total));
});
const bytesPercent = computed(() => {
  const j = job.value;
  if (!j || j.totalBytes <= 0) return 0;
  return Math.min(100, Math.round((j.bytes * 100) / j.totalBytes));
});
const stateText = computed(() => {
  const j = job.value;
  if (!j) return "";
  switch (j.state) {
    case "running":
      return j.phase === "scan" ? "正在统计文件…" : "导入中";
    case "done":
      return "导入完成";
    case "canceled":
      return "已取消";
    case "failed":
      return "导入失败";
    default:
      return "";
  }
});

function isBook(name: string) {
  return BOOK_EXT.test(name);
}

/** 非书籍文件不可勾选，避免用户选了图片才发现导不进去。 */
function selectable(row: WebDAVEntryView) {
  return row.isDir || isBook(row.name);
}

function iconOf(row: WebDAVEntryView) {
  if (row.isDir) return "📁";
  const ext = row.name.split(".").pop()?.toLowerCase() || "";
  if (ext === "epub") return "📗";
  if (ext === "pdf") return "📕";
  if (["zip", "cbz", "cbr", "rar", "7z"].includes(ext)) return "🖼️";
  return "📄";
}

async function load(p = curPath.value) {
  if (!props.configured) return;
  loading.value = true;
  try {
    const list = await webdavApi.list(p);
    // 目录在前、同类按名称排序：和文件管理器的习惯一致。
    entries.value = list.slice().sort((a, b) => {
      if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
      return a.name.localeCompare(b.name, "zh-CN");
    });
    selection.value = [];
  } catch (e) {
    ElMessage.error((e as Error).message);
    entries.value = [];
  } finally {
    loading.value = false;
  }
}

function go(p: string) {
  curPath.value = p;
  void load(p);
}

function enter(row: WebDAVEntryView) {
  if (!row.isDir) return;
  go(row.path);
}

function goUp() {
  const i = curPath.value.lastIndexOf("/");
  go(i < 0 ? "" : curPath.value.slice(0, i));
}

function onSelectionChange(rows: WebDAVEntryView[]) {
  selection.value = rows;
}

/** 汇总选中项会导入多少本书；目录会被递归展开。 */
async function summarize(): Promise<RemoteBookView[]> {
  const seen = new Set<string>();
  const out: RemoteBookView[] = [];
  for (const row of selection.value) {
    const books = row.isDir
      ? await webdavApi.scanBooks(row.path)
      : [
          {
            path: row.path,
            name: row.name,
            size: row.size,
            format: "",
            modTime: row.modTime ?? null,
          } as RemoteBookView,
        ];
    for (const b of books) {
      if (seen.has(b.path)) continue;
      seen.add(b.path);
      out.push(b);
    }
  }
  return out;
}

async function startImport() {
  if (!selection.value.length) return;
  const paths = selection.value.map((r) => r.path);

  let books: RemoteBookView[] = [];
  scanning.value = true;
  try {
    books = await summarize();
  } catch (e) {
    ElMessage.error((e as Error).message);
    return;
  } finally {
    scanning.value = false;
  }
  if (!books.length) {
    ElMessage.warning("所选位置里没有可导入的书籍文件（支持 txt / epub / pdf / zip / cbz）");
    return;
  }

  const bytes = books.reduce((sum, b) => sum + (b.size || 0), 0);
  try {
    await ElMessageBox.confirm(
      `将下载 ${books.length} 个文件（约 ${formatBytes(bytes)}）到本地并加入书架。` +
        `\n同名文件已存在且未更新时会直接复用，不会重复下载。`,
      "从 WebDAV 导入",
      { type: "info", confirmButtonText: "开始导入", cancelButtonText: "取消" },
    );
  } catch {
    return; // 用户取消
  }

  try {
    job.value = await webdavApi.startBookImport(paths);
    failures.value = [];
    ensurePolling();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function cancel() {
  try {
    await webdavApi.cancelBookImport();
    job.value = await webdavApi.bookImportStatus();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

function openFailures() {
  failures.value = job.value?.failures ?? [];
  showFailures.value = true;
}

// ── 进度：事件 + 轮询双通道 ─────────────────────────────────────────────

let pollTimer: number | null = null;

function stopPolling() {
  if (pollTimer !== null) {
    window.clearInterval(pollTimer);
    pollTimer = null;
  }
}

function ensurePolling() {
  if (pollTimer !== null) return;
  pollTimer = window.setInterval(async () => {
    try {
      const status = await webdavApi.bookImportStatus();
      job.value = status;
      if (status.state !== "running") {
        stopPolling();
        if (status.state === "done") {
          ElMessage.success(status.message || "导入完成");
        }
      }
    } catch {
      /* 单次失败不影响，下一轮再试 */
    }
  }, 1000);
}

type Unsubscribe = () => void;
let unsub: Unsubscribe | null = null;

/** 读一次最近一次任务的状态，切页签回来时不至于一片空白。 */
async function restoreStatus() {
  try {
    const status = await webdavApi.bookImportStatus();
    if (status.state !== "idle") {
      job.value = status;
      if (status.state === "running") ensurePolling();
    }
  } catch {
    /* 未配置时后端会直接报错，这里忽略即可 */
  }
}

onMounted(async () => {
  if (!props.configured) return;
  await load();
  try {
    unsub = onWebDAVImportProgress((data: WebDAVImportProgressPayload) => {
      // 事件只带进度字段，结果明细仍以 BookImportStatus 为准。
      job.value = {
        ...(job.value ?? {
          imported: [],
          failures: [],
          message: "",
          bytes: 0,
          totalBytes: 0,
        }),
        state: data.state,
        phase: data.phase,
        total: data.total,
        done: data.done,
        failed: data.failed,
        current: data.current,
        bytes: data.bytes,
        totalBytes: data.totalBytes,
        message: data.message,
      } as WebDAVImportJob;
      if (data.state === "running") ensurePolling();
      else stopPolling();
    }) as unknown as Unsubscribe;
  } catch {
    /* 事件订阅是增强能力，失败时由轮询兜底 */
  }

  await restoreStatus();
});

// 用户可能是先点进这个页签（当时看到"还没配置"），再去「连接配置」填好保存的。
// 若只在 onMounted 里初始化，配置补上后这里会永远停在空列表上。
watch(
  () => props.configured,
  async (ready) => {
    if (!ready) return;
    curPath.value = "";
    await load("");
    await restoreStatus();
  },
);

onBeforeUnmount(() => {
  stopPolling();
  if (unsub) unsub();
});
</script>

<template>
  <div class="import-panel">
    <el-alert
      v-if="!props.configured"
      type="info"
      :closable="false"
      show-icon
      title="还没有配置 WebDAV"
      description="先在「连接配置」里填写服务地址、用户名与密码并保存，再回到这里挑书。"
    />

    <template v-else>
      <div class="bar">
        <el-button size="small" :disabled="atRoot" @click="goUp">↑ 上级</el-button>
        <el-breadcrumb separator="/" class="crumbs">
          <el-breadcrumb-item v-for="c in crumbs" :key="c.path">
            <button class="crumb" @click="go(c.path)">{{ c.name }}</button>
          </el-breadcrumb-item>
        </el-breadcrumb>
        <span class="spacer" />
        <span class="hint">已选 {{ selection.length }} 项</span>
        <el-button size="small" :loading="loading" @click="load()">刷新</el-button>
        <el-button
          size="small"
          type="primary"
          :disabled="!selection.length || running"
          :loading="scanning"
          @click="startImport"
        >
          导入选中
        </el-button>
      </div>

      <el-table
        :data="entries"
        size="small"
        class="files"
        row-key="path"
        v-loading="loading"
        @row-dblclick="enter"
        @selection-change="onSelectionChange"
      >
        <el-table-column type="selection" width="42" :selectable="selectable" />
        <el-table-column label="名称" min-width="280">
          <template #default="{ row }">
            <span class="name" :class="{ dir: row.isDir, dim: !selectable(row) }">
              <span class="ico">{{ iconOf(row) }}</span>{{ row.name }}
            </span>
          </template>
        </el-table-column>
        <el-table-column label="大小" width="100">
          <template #default="{ row }">
            {{ row.isDir ? "—" : formatBytes(row.size) }}
          </template>
        </el-table-column>
        <el-table-column label="修改时间" width="110">
          <template #default="{ row }">{{ formatDateTime(row.modTime) }}</template>
        </el-table-column>
        <el-table-column label="操作" width="90">
          <template #default="{ row }">
            <el-button v-if="row.isDir" link type="primary" @click="enter(row)">进入</el-button>
            <span v-else-if="!selectable(row)" class="dim">不导入</span>
          </template>
        </el-table-column>
        <template #empty>
          <el-empty description="这个目录是空的" :image-size="72" />
        </template>
      </el-table>

      <div v-if="job && job.state !== 'idle'" class="job">
        <div class="job-head">
          <span class="state" :class="job.state">{{ stateText }}</span>
          <span v-if="job.total > 0" class="count">
            {{ job.done + job.failed }} / {{ job.total }}
            <template v-if="job.failed > 0">（失败 {{ job.failed }}）</template>
          </span>
          <span class="spacer" />
          <el-button v-if="running" size="small" @click="cancel">取消</el-button>
          <el-button v-if="job.state === 'done'" size="small" type="primary" @click="router.push('/')">
            去书架
          </el-button>
          <el-button v-if="job.failures?.length" size="small" link @click="openFailures">
            查看失败项
          </el-button>
        </div>
        <el-progress
          :percentage="job.phase === 'scan' ? 0 : percent"
          :status="job.state === 'failed' ? 'exception' : job.state === 'running' ? undefined : 'success'"
          :indeterminate="running && job.phase === 'scan'"
          :stroke-width="8"
        />
        <div class="job-line">
          <span v-if="job.current" class="current">{{ job.current }}</span>
          <span class="msg">{{ job.message }}</span>
          <span v-if="running && job.totalBytes > 0" class="bytes">
            {{ formatBytes(job.bytes) }} / {{ formatBytes(job.totalBytes) }}（{{ bytesPercent }}%）
          </span>
        </div>
      </div>
    </template>

    <el-dialog v-model="showFailures" title="导入失败的文件" width="620">
      <el-table :data="failures" size="small">
        <el-table-column prop="path" label="远端路径" min-width="240" />
        <el-table-column prop="reason" label="原因" min-width="240" />
        <template #empty><el-empty description="没有失败项" :image-size="60" /></template>
      </el-table>
    </el-dialog>
  </div>
</template>

<style scoped>
.import-panel {
  padding: 8px 0;
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.bar {
  display: flex;
  align-items: center;
  gap: 8px;
}
.crumbs {
  display: flex;
  align-items: center;
}
.crumb {
  font: inherit;
  font-size: 13px;
  color: #0969da;
  background: none;
  border: none;
  padding: 0 2px;
  cursor: pointer;
}
.crumb:hover {
  text-decoration: underline;
}
.spacer {
  flex: 1;
}
.hint {
  font-size: 12px;
  color: #57606a;
}
.files {
  flex: 1;
  min-height: 240px;
}
.name {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  cursor: default;
}
.name.dir {
  cursor: pointer;
  font-weight: 500;
}
.name.dim {
  color: #8c959f;
}
.dim {
  color: #8c959f;
  font-size: 12px;
}
.ico {
  font-size: 14px;
}
.job {
  border: 1px solid #d8dee4;
  border-radius: 8px;
  padding: 10px 12px;
  background: #fafbfc;
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.job-head {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 13px;
}
.state {
  font-weight: 600;
}
.state.running {
  color: #0969da;
}
.state.done {
  color: #1a7f37;
}
.state.failed {
  color: #cf222e;
}
.state.canceled {
  color: #9a6700;
}
.count {
  color: #57606a;
}
.job-line {
  display: flex;
  gap: 10px;
  font-size: 12px;
  color: #57606a;
  flex-wrap: wrap;
}
.current {
  color: #1f2328;
}
</style>
