<script setup lang="ts">
/**
 * 扩展包下载源选择对话框。
 *
 * 为什么是弹窗而不是设置页里的一行下拉：源能不能用**取决于要下哪个包**
 * （jsDelivr 单文件上限 20 MB，全量包的源文件 63 MB 用它必然 403）。
 * 放在包旁边、按包过滤，用户永远看不到「选了却注定失败」的组合。
 */
import { computed, ref, watch } from "vue";
import { ElMessage } from "element-plus";

import { dictApi } from "@/api/dict";
import type { DictSourceView } from "@/api/dict";
import { toMessage } from "@/api/client";
import { systemApi } from "@/api/system";
import { useDictStore } from "@/stores/dict";

const props = defineProps<{
  modelValue: boolean;
  packId: string;
  packName: string;
  /** 需要下载的源文件体积（字节），用于提示「下多大」。 */
  downloadBytes?: number;
}>();

const emit = defineEmits<{ "update:modelValue": [v: boolean] }>();

const dict = useDictStore();

const mode = ref<"auto" | "manual">("auto");
const selected = ref("");
const customUrl = ref("");
const sources = ref<DictSourceView[]>([]);
const loading = ref(false);
const probing = ref(false);
const probeText = ref("");
const previewUrl = ref("");
const previewError = ref("");
const customKind = ref("");
const starting = ref(false);

const visible = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit("update:modelValue", v),
});

const sizeText = computed(() => {
  const b = props.downloadBytes ?? 0;
  if (b <= 0) return "";
  return b < 1 << 20 ? `${Math.round(b / 1024)} KB` : `${(b / (1 << 20)).toFixed(1)} MB`;
});

/** 自动模式下列表按先后顺序展示，只需要能用的那些。 */
const autoList = computed(() => sources.value.filter((s) => s.usable));

const selectedLabel = computed(
  () => sources.value.find((s) => s.id === selected.value)?.name ?? "",
);

async function load() {
  loading.value = true;
  probeText.value = "";
  try {
    const [list, cfg] = await Promise.all([
      dict.sources(props.packId),
      dict.sourceConfig(props.packId),
    ]);
    sources.value = list;
    mode.value = cfg.mode === "manual" ? "manual" : "auto";
    customUrl.value = cfg.customUrl ?? "";
    // 保存的源可能在当前包下不可用（例如上次给汉英包选了 jsDelivr），
    // 这时回退到第一个可用项，而不是让用户面对一个选不中的状态。
    const saved = list.find((s) => s.id === cfg.sourceId);
    selected.value = saved?.usable
      ? saved.id
      : (list.find((s) => s.usable)?.id ?? "");
    await refreshPreview();
  } catch (err) {
    ElMessage.error(toMessage(err));
  } finally {
    loading.value = false;
  }
}

/** 预演最终请求地址。后端只拼字符串，不发请求。 */
async function refreshPreview() {
  if (!selected.value) return;
  try {
    const cfg = await dictApi.preview(
      props.packId,
      selected.value,
      selected.value === "custom" ? customUrl.value : "",
    );
    previewUrl.value = cfg.previewUrl ?? "";
    previewError.value = cfg.previewError ?? "";
    customKind.value = cfg.customKind ?? "";
  } catch (err) {
    previewError.value = toMessage(err);
    previewUrl.value = "";
  }
}

watch(
  () => props.modelValue,
  (v) => {
    if (v) void load();
  },
);

// 切换源/改地址就重新回显。250ms 防抖：输入时每个键都发一次 IPC 没必要。
let previewTimer: ReturnType<typeof setTimeout> | null = null;
watch([selected, customUrl], () => {
  if (previewTimer) clearTimeout(previewTimer);
  previewTimer = setTimeout(() => void refreshPreview(), 250);
});

/** 测速。结果显示但**不预置**：没测之前不显示任何猜测值。 */
async function probe() {
  if (!selected.value) return;
  probing.value = true;
  probeText.value = "测速中…";
  try {
    const res = await dict.probe(
      props.packId,
      selected.value,
      selected.value === "custom" ? customUrl.value : "",
    );
    if (!res.ok) {
      probeText.value = `不可用：${res.err || `HTTP ${res.httpCode}`}`;
    } else if (res.err) {
      probeText.value = `${Math.round(res.kbps ?? 0)} KB/s（${res.err}）`;
    } else {
      probeText.value = `${Math.round(res.kbps ?? 0)} KB/s · ${res.rangeOk ? "支持续传" : "不支持续传"}`;
    }
  } catch (err) {
    probeText.value = toMessage(err);
  } finally {
    probing.value = false;
  }
}

async function start() {
  const pick = mode.value === "manual" ? selected.value : "";
  if (mode.value === "manual" && !pick) {
    ElMessage.warning("请选择一个下载源");
    return;
  }
  starting.value = true;
  try {
    await dict.setSource(mode.value, pick || selected.value, customUrl.value);
    await dict.install(
      props.packId,
      mode.value === "manual" ? pick : "",
      mode.value === "manual" && pick === "custom" ? customUrl.value : "",
    );
    ElMessage.success("已开始下载，进度可在本页查看");
    visible.value = false;
  } catch (err) {
    ElMessage.error(toMessage(err));
  } finally {
    starting.value = false;
  }
}

/** 导入本地文件：所有镜像都挂掉时的唯一出路。 */
async function importLocal() {
  try {
    const paths = await systemApi.openDictFile();
    if (!paths.length) return;
    await dict.importFile(props.packId, paths[0]);
    ElMessage.success("已开始转换本地文件");
    visible.value = false;
  } catch (err) {
    ElMessage.error(toMessage(err));
  }
}
</script>

<template>
  <el-dialog v-model="visible" :title="`下载「${packName}」`" width="520px" data-dict="source-dialog">
    <div v-loading="loading" class="dsd">
      <p v-if="sizeText" class="dsd-size">
        需下载约 {{ sizeText }} 的源文件，下载后在本机转换成词库（转换过程不联网）。
      </p>

      <el-radio-group v-model="mode" class="dsd-mode">
        <el-radio value="auto">自动（依次尝试，推荐）</el-radio>
        <el-radio value="manual">指定下载源</el-radio>
      </el-radio-group>

      <!-- 自动模式：只列出会按顺序尝试的源，明确告诉用户"等下会这样走" -->
      <ol v-if="mode === 'auto'" class="dsd-auto" data-dict="source-auto">
        <li v-for="s in autoList" :key="s.id">
          <span class="dsd-name">{{ s.name }}</span>
          <span v-if="s.note" class="dsd-note">{{ s.note }}</span>
        </li>
        <li v-if="!autoList.length" class="dsd-empty">
          没有可用的下载源，请改用「指定下载源」或导入本地文件。
        </li>
      </ol>

      <template v-else>
        <el-radio-group v-model="selected" class="dsd-sources" data-dict="source-list">
          <el-radio
            v-for="s in sources"
            :key="s.id"
            :value="s.id"
            :disabled="!s.usable"
            class="dsd-source"
          >
            <span class="dsd-name">{{ s.name }}</span>
            <span v-if="!s.usable" class="dsd-reason" data-dict="source-reason">
              {{ s.reason }}
            </span>
            <span v-else-if="s.note" class="dsd-note">{{ s.note }}</span>
          </el-radio>
        </el-radio-group>

        <div v-if="selected === 'custom'" class="dsd-custom">
          <el-input
            v-model="customUrl"
            placeholder="https://ghfast.top 或 https://your.host/packs/ecdict.csv"
            clearable
            data-dict="custom-url"
          />
          <p class="dsd-hint">
            三种写法都认：以 <code>{url}</code> 为占位符的模板、前缀镜像地址（自动拼接上游地址）、
            指向具体文件的完整地址。
          </p>
        </div>
      </template>

      <!-- 回显：这是防「填了却生效成另一种意思」的关键 -->
      <div v-if="mode === 'manual'" class="dsd-preview" data-dict="preview">
        <div v-if="customKind" class="dsd-preview-kind">识别为：{{ customKind }}</div>
        <div v-if="previewUrl" class="dsd-preview-url">将请求：{{ previewUrl }}</div>
        <div v-else-if="previewError" class="dsd-preview-err">{{ previewError }}</div>
      </div>

      <div v-if="mode === 'manual'" class="dsd-probe">
        <el-button size="small" :loading="probing" :disabled="!selected" @click="probe">
          测速「{{ selectedLabel }}」
        </el-button>
        <span v-if="probeText" class="dsd-note" data-dict="probe-result">{{ probeText }}</span>
      </div>
    </div>

    <template #footer>
      <el-button link :disabled="starting" @click="importLocal">导入本地文件…</el-button>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="starting" data-dict="source-start" @click="start">
        开始下载
      </el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.dsd {
  min-width: 0;
  max-width: 100%;
}
.dsd-size {
  margin: 0 0 var(--r-pad);
  color: #606266;
  font-size: 13px;
  min-width: 0;
}
.dsd-mode {
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
  margin-bottom: var(--r-pad-sm);
}
.dsd-auto {
  margin: 0 0 var(--r-pad-sm);
  padding-left: 20px;
  min-width: 0;
  max-width: 100%;
  color: #303133;
  font-size: 13px;
}
.dsd-auto li {
  margin-bottom: 4px;
  min-width: 0;
}
.dsd-sources {
  display: flex;
  flex-direction: column;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
}
.dsd-source {
  height: auto;
  margin-right: 0;
  padding: var(--r-pad-sm) 0;
  min-width: 0;
  max-width: 100%;
}
.dsd-name {
  font-weight: 500;
  min-width: 0;
}
.dsd-note {
  color: #909399;
  font-size: 12px;
  margin-left: var(--r-gap-sm);
  min-width: 0;
  word-break: break-word;
}
.dsd-reason {
  color: #c45656;
  font-size: 12px;
  margin-left: var(--r-gap-sm);
  min-width: 0;
  word-break: break-word;
}
.dsd-empty {
  color: #c45656;
  font-size: 13px;
}
.dsd-custom {
  margin-top: var(--r-pad-sm);
  min-width: 0;
  max-width: 100%;
}
.dsd-hint {
  margin: var(--r-pad-sm) 0 0;
  min-width: 0;
  word-break: break-word;
  color: #909399;
  font-size: 12px;
  line-height: 1.5;
}
.dsd-hint code {
  background: #f2f3f5;
  padding: 0 4px;
  border-radius: var(--r-radius-sm);
}
.dsd-preview {
  margin-top: var(--r-pad-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  max-width: 100%;
  word-break: break-word;
  background: #f7f8fa;
  border-radius: var(--r-radius-sm);
  font-size: 12px;
  line-height: 1.6;
}
.dsd-preview-kind {
  color: #909399;
}
.dsd-preview-url {
  color: #303133;
  min-width: 0;
  word-break: break-all;
}
.dsd-preview-err {
  color: #f56c6c;
}
.dsd-probe {
  margin-top: var(--r-pad-sm);
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
}
:deep(.el-dialog__footer) {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: var(--r-gap-sm);
}

@media (max-width: 640px) {
  .dsd-preview {
    padding: var(--r-pad-sm);
  }
  .dsd-note,
  .dsd-reason {
    margin-left: 0;
  }
}
</style>
