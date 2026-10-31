<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import { replaceRuleApi } from "@/api/replacerule";
import { systemApi } from "@/api/system";
import { rawFileURL } from "@/api/system";
import { usePlatformStore } from "@/stores/platform";
import type { ReplaceRuleView } from "@/types";

const platform = usePlatformStore();
/**
 * 窄屏判定：移动端把编辑弹窗做成全屏。
 * 不做的话输入区只剩几行高，规则原文根本没法改——这类页面在手机上
 * 全屏编辑比留白更能用。
 */
const isNarrow = computed(() => platform.isMobile);

const rules = ref<ReplaceRuleView[]>([]);
const loading = ref(false);
const keyword = ref("");

// ── 编辑弹窗 ────────────────────────────────────────────────
const dialog = ref(false);
const form = ref({
  id: 0,
  name: "",
  group: "",
  enabled: true,
  raw: "[]",
});
/** 规则原文的解析错误；为空表示当前文本是合法 JSON。 */
const rawError = ref("");

function openCreate() {
  form.value = { id: 0, name: "", group: "", enabled: true, raw: "[]" };
  rawError.value = "";
  dialog.value = true;
}

function openEdit(r: ReplaceRuleView) {
  form.value = {
    id: r.id,
    name: r.name,
    group: r.group,
    enabled: r.enabled,
    raw: r.raw || "[]",
  };
  rawError.value = "";
  dialog.value = true;
}

/** 边写边校验：规则原文必须是 JSON 数组，否则入库后阅读器解析时才发现就晚了。 */
function checkRaw() {
  const text = form.value.raw.trim();
  if (!text) {
    rawError.value = "";
    return;
  }
  try {
    const v = JSON.parse(text);
    if (!Array.isArray(v)) rawError.value = "规则原文必须是数组（[] 包裹）";
    else rawError.value = "";
  } catch (e) {
    rawError.value = "JSON 解析失败：" + (e as Error).message;
  }
}

/** 追加一条「正则替换」样例，省得用户去查格式。 */
function appendSample() {
  let list: unknown[] = [];
  try {
    const v = JSON.parse(form.value.raw || "[]");
    if (Array.isArray(v)) list = v;
  } catch {
    /* 当前不是合法数组就整体替换成新的 */
    list = [];
  }
  list.push({
    regex: "^\\s*广告.*$",
    replacement: "",
    scope: "content",
    isRegex: true,
  });
  form.value.raw = JSON.stringify(list, null, 2);
  checkRaw();
}

async function submit() {
  if (!form.value.name.trim()) {
    ElMessage.warning("请填写规则名称");
    return;
  }
  checkRaw();
  if (rawError.value) {
    ElMessage.warning(rawError.value);
    return;
  }
  await replaceRuleApi.save(
    form.value.id,
    form.value.name.trim(),
    form.value.group.trim(),
    form.value.raw,
    form.value.enabled,
  );
  ElMessage.success("已保存");
  dialog.value = false;
  await load();
}

async function load() {
  loading.value = true;
  try {
    rules.value = await replaceRuleApi.list();
  } finally {
    loading.value = false;
  }
}

async function remove(r: ReplaceRuleView) {
  try {
    await ElMessageBox.confirm(`确定删除规则「${r.name}」？`, "删除替换规则", {
      confirmButtonText: "删除",
      cancelButtonText: "取消",
      type: "warning",
    });
  } catch {
    return;
  }
  await replaceRuleApi.delete(r.id);
  ElMessage.success("已删除");
  await load();
}

async function toggle(r: ReplaceRuleView, enabled: boolean) {
  await replaceRuleApi.setEnabled(r.id, enabled);
  await load();
}

// ── 导入导出 ────────────────────────────────────────────────
async function importRules() {
  const paths = await systemApi.openSourceFile();
  if (!paths || paths.length === 0) return;
  try {
    const text = await readTextFile(paths[0]);
    const res = await replaceRuleApi.import(text, true);
    if (!res) return;
    ElMessage.success(
      `导入完成：新增 ${res.imported}，更新 ${res.updated}，失败 ${(res.failures ?? []).length}`,
    );
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function exportRules() {
  try {
    const json = await replaceRuleApi.export([]);
    const dest = await systemApi.saveFile("导出替换规则", "replaceRules.json");
    if (!dest) return;
    await systemApi.saveTextFile(dest, json ?? "");
    ElMessage.success(`已导出到 ${dest}`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function readTextFile(absPath: string): Promise<string> {
  const resp = await fetch(rawFileURL(absPath));
  if (!resp.ok) throw new Error("无法读取文件");
  return resp.text();
}

/** 子规则条数：让用户不打开编辑也能看出这条规则是空的还是有内容的。 */
function ruleCount(r: ReplaceRuleView): number {
  if (!r.raw) return 0;
  try {
    const v = JSON.parse(r.raw);
    return Array.isArray(v) ? v.length : 0;
  } catch {
    return 0;
  }
}

const filtered = computed(() => {
  const k = keyword.value.trim().toLowerCase();
  if (!k) return rules.value;
  return rules.value.filter(
    (r) =>
      r.name.toLowerCase().includes(k) || r.group.toLowerCase().includes(k),
  );
});

onMounted(load);
</script>

<template>
  <div class="rule-view">
    <header class="toolbar">
      <el-input
        v-model="keyword"
        placeholder="搜索规则"
        clearable
        class="search"
      />
      <div class="spacer" />
      <el-button @click="exportRules">导出</el-button>
      <el-button @click="importRules">导入</el-button>
      <el-button type="primary" @click="openCreate">新建</el-button>
    </header>

    <div v-loading="loading" class="list">
      <div v-for="r in filtered" :key="r.id" class="rule-card">
        <div class="rule-main">
          <div class="rule-name">{{ r.name }}</div>
          <div class="rule-meta">
            <span v-if="r.group" class="tag">{{ r.group }}</span>
            <span class="count">{{ ruleCount(r) }} 条子规则</span>
          </div>
        </div>
        <div class="rule-actions">
          <el-switch
            :model-value="r.enabled"
            @change="(v: boolean) => toggle(r, v)"
          />
          <el-button link type="primary" @click="openEdit(r)">编辑</el-button>
          <el-button link type="danger" @click="remove(r)">删除</el-button>
        </div>
      </div>
      <el-empty
        v-if="!loading && filtered.length === 0"
        description="还没有替换规则，新建一条或导入一份"
      />
    </div>

    <el-dialog
      v-model="dialog"
      :title="form.id ? '编辑替换规则' : '新建替换规则'"
      class="rule-dialog"
      :fullscreen="isNarrow"
      width="560"
    >
      <el-form label-position="top">
        <el-form-item label="名称">
          <el-input v-model="form.name" placeholder="例如：去除广告行" />
        </el-form-item>
        <el-form-item label="分组">
          <el-input v-model="form.group" placeholder="可留空" />
        </el-form-item>
        <el-form-item label="启用">
          <el-switch v-model="form.enabled" />
        </el-form-item>
        <el-form-item label="规则原文（JSON 数组）">
          <el-input
            v-model="form.raw"
            type="textarea"
            :rows="10"
            spellcheck="false"
            @input="checkRaw"
          />
          <div v-if="rawError" class="raw-error">{{ rawError }}</div>
          <div class="raw-hint">
            每条子规则形如
            <code>{"regex":"...","replacement":"","scope":"content","isRegex":true}</code>
            <el-button link type="primary" @click="appendSample">
              插入样例
            </el-button>
          </div>
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="dialog = false">取消</el-button>
        <el-button type="primary" @click="submit">保存</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.rule-view {
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
  flex-wrap: wrap;
}
.search {
  width: 240px;
  max-width: 100%;
}
.spacer {
  flex: 1;
}
/* 卡片列表而非表格：同一套标记在 360px 到 1200px 下都读得顺，
   表格在窄屏只能横向滚动，操作列还会被挤出去。 */
.list {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding: 0 16px;
}
.rule-card {
  display: flex;
  align-items: center;
  gap: 12px;
  flex-wrap: wrap;
  padding: 12px 14px;
  margin-bottom: 8px;
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: 10px;
}
.rule-main {
  min-width: 0;
  flex: 1;
}
.rule-name {
  font-size: 14px;
  font-weight: 600;
  color: #1f2328;
  word-break: break-all;
}
.rule-meta {
  margin-top: 4px;
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12px;
  color: #6b7280;
}
.tag {
  padding: 1px 6px;
  border-radius: 4px;
  background: #f3f4f6;
}
.rule-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  flex: none;
}
.raw-error {
  margin-top: 4px;
  font-size: 12px;
  color: #dc2626;
}
.raw-hint {
  margin-top: 4px;
  font-size: 12px;
  color: #6b7280;
  line-height: 1.6;
}
.raw-hint code {
  background: #f3f4f6;
  padding: 1px 4px;
  border-radius: 3px;
}

@media (max-width: 640px) {
  .toolbar {
    padding: 10px 12px;
  }
  .search {
    width: 100%;
  }
  .list {
    padding: 0 12px;
  }
  /* 窄屏下操作区独占一行，避免和开关挤在一起误触 */
  .rule-actions {
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
