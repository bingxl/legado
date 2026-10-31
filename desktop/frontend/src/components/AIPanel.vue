<script setup lang="ts">
/**
 * 书籍详情页的「AI 总结」面板。
 *
 * 职责边界：只做「这本书的索引状态 + 范围选择 + 摘要展示」。
 * 问答会话在独立的 AIView（M3）里，本面板不掺和。
 *
 * 状态来自 stores/aiIndex：索引是后台长任务，用户切走页面再回来要能看到
 * 仍在跑的进度，所以状态不能只放在组件的生命周期里。
 */
import { computed, onMounted, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import { AIScope, aiApi } from "@/api/ai";
import type { AIScopeValue } from "@/api/ai";
import { indexPercent, phaseLabel, useAIIndexStore } from "@/stores/aiIndex";
import type { ChapterItem } from "@/types";

const props = defineProps<{
  bookId: number;
  chapters: ChapterItem[];
  /** 当前阅读进度（章节序号），用于「已读」范围的提示。 */
  readIndex: number;
  /** 是否已经开始读这本书（决定默认索引范围）。 */
  started: boolean;
  /** 当前 Tab 是否处于激活状态：切回来时要重新拉一次权威状态。 */
  active: boolean;
}>();

const store = useAIIndexStore();

/** 有正文的章节（分卷标题不是正文，建索引时会跳过）。 */
const contentChapters = computed(() =>
  props.chapters.filter((c) => !c.isVolume),
);
const firstIndex = computed(() => contentChapters.value[0]?.index ?? 0);
const lastIndex = computed(
  () => contentChapters.value[contentChapters.value.length - 1]?.index ?? 0,
);
const hasProgress = computed(() => props.started);

const scope = ref<AIScopeValue>(AIScope.All);
const rangeFrom = ref(0);
const rangeTo = ref(0);

const status = computed(() => store.statusOf(props.bookId));
const running = computed(() => status.value?.status === "running");
const phase = computed(() => store.phaseOf(props.bookId));
const percent = computed(() => indexPercent(status.value));
const hasIndex = computed(() => (status.value?.chunkCount ?? 0) > 0);
const summaryText = computed(() => status.value?.summary || "");
const errorText = computed(() => status.value?.error || "");

/** 状态卡片的标题行。 */
const statusLabel = computed(() => {
  switch (status.value?.status) {
    case "running":
      return phase.value ? `${phaseLabel(phase.value.phase)}进行中` : "索引进行中";
    case "done":
      return "索引已就绪";
    case "failed":
      return "索引失败";
    case "canceled":
      return "已取消";
    default:
      return "尚未建立索引";
  }
});

/** 「已读」范围的结束章：没有进度时退化成第一章（与后端一致）。 */
const readRangeLabel = computed(() => {
  const end = hasProgress.value ? props.readIndex : firstIndex.value;
  return `已读：第 ${firstIndex.value + 1} ~ ${end + 1} 章`;
});

const canStart = computed(() => contentChapters.value.length > 0 && !running.value);
const rangeValid = computed(
  () => rowFrom() >= firstIndex.value && rowTo() <= lastIndex.value && rowFrom() <= rowTo(),
);

function rowFrom() {
  return Number.isFinite(rangeFrom.value) ? rangeFrom.value : firstIndex.value;
}
function rowTo() {
  return Number.isFinite(rangeTo.value) ? rangeTo.value : lastIndex.value;
}

/** 快速总结用的人话结果（不写索引表，只调一次模型）。 */
const quickText = ref("");
const quickLoading = ref(false);
/** 首次读取状态中：此时不渲染缓存里的旧状态。 */
const loading = ref(true);

function resetRange() {
  rangeFrom.value = firstIndex.value;
  rangeTo.value = lastIndex.value;
}

async function load() {
  if (!props.bookId) {
    loading.value = false;
    return;
  }
  resetRange();
  scope.value = hasProgress.value ? AIScope.Read : AIScope.All;
  loading.value = true;
  try {
    await store.refresh(props.bookId);
  } finally {
    loading.value = false;
  }
}

async function startIndex() {
  if (scope.value === AIScope.Range && !rangeValid.value) {
    ElMessage.warning(`请填写 ${firstIndex.value + 1} ~ ${lastIndex.value + 1} 之间的章节`);
    return;
  }
  try {
    await store.start(
      props.bookId,
      scope.value,
      scope.value === AIScope.Range ? rowFrom() : 0,
      scope.value === AIScope.Range ? rowTo() : 0,
    );
    ElMessage.success("已开始建立索引，可以离开本页，进度会在顶部显示");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function cancelIndex() {
  try {
    await store.cancel(props.bookId);
    ElMessage.info("已取消索引");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function deleteIndex() {
  try {
    await ElMessageBox.confirm(
      "删除后摘要与切片都会清空，需要重新生成（会再次消耗模型调用）。",
      "删除这本书的 AI 索引？",
      { type: "warning", confirmButtonText: "删除", cancelButtonText: "算了" },
    );
  } catch {
    return;
  }
  try {
    await store.remove(props.bookId);
    quickText.value = "";
    ElMessage.success("已删除索引");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 只想看这几章讲了什么时走轻量路径：不切片、不向量化、不落库。 */
async function quickSummary() {
  if (!rangeValid.value) {
    ElMessage.warning(`请填写 ${firstIndex.value + 1} ~ ${lastIndex.value + 1} 之间的章节`);
    return;
  }
  quickLoading.value = true;
  try {
    quickText.value = await aiApi.summarizeChapters(
      props.bookId,
      rowFrom(),
      rowTo(),
    );
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    quickLoading.value = false;
  }
}

watch(() => props.bookId, load);
watch(
  () => props.active,
  (on) => {
    // 切回本 Tab 时重新拉一次：索引可能在别处被删掉（另一个窗口、清理任务），
    // 只靠事件与轮询会显示上一条过期状态。
    if (on) store.refresh(props.bookId).catch(() => {});
  },
);
onMounted(load);
</script>

<template>
  <div class="ai-panel">
    <!-- 首次读取状态：store 里可能还留着这本书上一次的缓存，
         直接渲染会先闪一下过期状态（刚删完索引却显示「已就绪」）。
         等 refresh 回来再铺内容，卡片也就成了「数据就绪」的信号。 -->
    <div v-if="loading" class="card" data-ai="loading">
      <div class="card-head">
        <span class="dot idle" />
        <span class="card-title">正在读取索引状态…</span>
      </div>
    </div>

    <!-- 状态卡片 -->
    <div v-else class="card" data-ai="status-card">
      <div class="card-head">
        <span class="dot" :class="status?.status || 'idle'" />
        <span class="card-title" data-ai="status-text">{{ statusLabel }}</span>
        <span v-if="hasIndex" class="muted" data-ai="chunk-count">
          {{ status?.chunkCount }} 片 · 向量 {{ status?.vectorCount }} 片
        </span>
      </div>

      <div v-if="running" class="progress-wrap">
        <el-progress :percentage="percent" :stroke-width="6" />
        <div class="progress-text" data-ai="progress-message">
          {{ phase?.message || `${phaseLabel(phase?.phase || "")}…` }}
        </div>
      </div>

      <p v-if="errorText" class="hint warn" data-ai="index-error">{{ errorText }}</p>
      <p v-else-if="!hasIndex && !running" class="hint">
        建立索引后可以按语义检索全书内容，用于问答与摘要。网络书建议先「缓存」，
        否则索引会边抓边算，耗时很长。
      </p>
    </div>

    <!-- 范围与操作 -->
    <div class="card">
      <div class="field-label">索引范围</div>
      <el-radio-group v-model="scope" :disabled="running" class="scopes">
        <el-radio :value="AIScope.All"><span data-ai="scope-all">全书</span></el-radio>
        <el-radio :value="AIScope.Read">
          <span data-ai="scope-read">已读部分</span>
          <span v-if="hasProgress" class="muted">（{{ readRangeLabel }}）</span>
        </el-radio>
        <el-radio :value="AIScope.Range">
          <span data-ai="scope-range">指定章节</span>
        </el-radio>
      </el-radio-group>

      <div v-if="scope === AIScope.Range" class="range-row">
        <el-input
          v-model.number="rangeFrom"
          type="number"
          size="small"
          class="range-input"
          data-ai="range-from"
          :disabled="running"
        />
        <span class="range-sep">至</span>
        <el-input
          v-model.number="rangeTo"
          type="number"
          size="small"
          class="range-input"
          data-ai="range-to"
          :disabled="running"
        />
        <span class="muted">
          有效范围 {{ firstIndex + 1 }} ~ {{ lastIndex + 1 }}
        </span>
      </div>

      <div class="actions">
        <el-button
          v-if="running"
          type="danger"
          plain
          data-ai="cancel-index"
          @click="cancelIndex"
        >取消索引</el-button>
        <template v-else>
          <el-button
            type="primary"
            data-ai="start-index"
            :disabled="!canStart"
            @click="startIndex"
          >{{ hasIndex ? "重新生成" : "生成索引" }}</el-button>
          <el-button
            v-if="hasIndex"
            data-ai="delete-index"
            @click="deleteIndex"
          >删除索引</el-button>
        </template>
      </div>
    </div>

    <!-- 全书摘要 -->
    <div v-if="!loading && summaryText" class="card">
      <div class="card-head">
        <span class="card-title">全书摘要</span>
        <span v-if="status?.updatedAt" class="muted">
          {{ new Date(status.updatedAt).toLocaleString() }}
        </span>
      </div>
      <p class="summary" data-ai="summary">{{ summaryText }}</p>
    </div>

    <!-- 轻量总结：只看这几章，不建索引 -->
    <div class="card">
      <div class="card-head">
        <span class="card-title">只看这几章讲了什么</span>
        <span class="muted">不建立索引，只调用一次模型</span>
      </div>
      <div class="actions">
        <el-button
          size="small"
          data-ai="quick-summary"
          :loading="quickLoading"
          @click="quickSummary"
        >总结当前所选范围</el-button>
      </div>
      <p v-if="quickText" class="summary" data-ai="quick-summary-text">
        {{ quickText }}
      </p>
    </div>
  </div>
</template>

<style scoped>
.ai-panel {
  display: flex;
  flex-direction: column;
  gap: 12px;
}
.card {
  border: 1px solid #eef0f3;
  border-radius: 8px;
  padding: 12px 14px;
  background: #fafbfc;
}
.card-head {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-bottom: 6px;
}
.card-title {
  font-size: 14px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
}
.dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #c0c4cc;
  flex: none;
}
.dot.running {
  background: #409eff;
}
.dot.done {
  background: #67c23a;
}
.dot.failed {
  background: #f56c6c;
}
.dot.canceled {
  background: #e6a23c;
}
.muted {
  font-size: 12px;
  color: rgba(0, 0, 0, 0.45);
}
.hint {
  margin: 6px 0 0;
  font-size: 12px;
  line-height: 1.6;
  color: rgba(0, 0, 0, 0.55);
}
.hint.warn {
  color: #e6a23c;
}
.progress-wrap {
  margin-top: 8px;
}
.progress-text {
  margin-top: 4px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.55);
}
.field-label {
  font-size: 13px;
  color: rgba(0, 0, 0, 0.7);
  margin-bottom: 6px;
}
.scopes {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}
.range-row {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 8px;
  flex-wrap: wrap;
}
.range-input {
  width: 92px;
}
.range-sep {
  font-size: 12px;
  color: rgba(0, 0, 0, 0.45);
}
.actions {
  display: flex;
  gap: 8px;
  margin-top: 12px;
  flex-wrap: wrap;
}
.summary {
  margin: 6px 0 0;
  font-size: 13px;
  line-height: 1.75;
  color: rgba(0, 0, 0, 0.75);
  white-space: pre-wrap;
}
</style>
