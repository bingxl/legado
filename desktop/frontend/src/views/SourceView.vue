<script setup lang="ts">
import { onMounted, ref } from "vue";
import { ElMessage } from "element-plus";

import { sourceApi } from "@/api/source";
import { systemApi } from "@/api/system";
import { onSourceCheckProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";
import type { SourceView, SourceCheckResult } from "@/types";

const sources = ref<SourceView[]>([]);
const loading = ref(false);
const keyword = ref("");
const checkProgress = ref<ProgressPayload | null>(null);

// ── 编辑弹窗 ────────────────────────────────────────────────
const editDialog = ref(false);
const form = ref({
  id: 0,
  name: "",
  group: "",
  url: "",
  comment: "",
  raw: "",
  enabled: true,
  order: 0,
});

async function load() {
  loading.value = true;
  try {
    sources.value = await sourceApi.list("");
  } finally {
    loading.value = false;
  }
}

function openCreate() {
  form.value = {
    id: 0,
    name: "",
    group: "",
    url: "",
    comment: "",
    raw: "",
    enabled: true,
    order: 0,
  };
  editDialog.value = true;
}

function openEdit(s: SourceView) {
  form.value = { ...s };
  editDialog.value = true;
}

async function save() {
  try {
    await sourceApi.save(
      form.value.id,
      form.value.name,
      form.value.group,
      form.value.url,
      form.value.comment,
      form.value.raw,
      form.value.enabled,
      form.value.order,
    );
    editDialog.value = false;
    await load();
    ElMessage.success("已保存");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function remove(s: SourceView) {
  await sourceApi.delete(s.id);
  await load();
  ElMessage.success("已删除");
}

async function toggle(s: SourceView, enabled: boolean) {
  await sourceApi.setEnabled(s.id, enabled);
  await load();
}

// ── 导入导出 ────────────────────────────────────────────────
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
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
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
  const url = "/raw/?p=" + encodeURIComponent(absPath);
  const resp = await fetch(url);
  if (!resp.ok) throw new Error("无法读取文件");
  return resp.text();
}

// ── 校验 ────────────────────────────────────────────────────
const checkDialog = ref(false);
const checkResults = ref<SourceCheckResult[]>([]);

async function validate() {
  checkDialog.value = true;
  checkResults.value = [];
  try {
    checkResults.value = (await sourceApi.validate([])) ?? [];
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

const filtered = () => {
  const k = keyword.value.trim().toLowerCase();
  if (!k) return sources.value;
  return sources.value.filter(
    (s) =>
      s.name.toLowerCase().includes(k) ||
      s.group.toLowerCase().includes(k) ||
      s.url.toLowerCase().includes(k),
  );
};

onMounted(() => {
  load();
  onSourceCheckProgress((data) => {
    checkProgress.value = data;
  });
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
      <el-button @click="importSources">导入</el-button>
      <el-button type="primary" @click="openCreate">新建</el-button>
    </header>

    <div class="progress" v-if="checkProgress">
      校验中 {{ checkProgress.done }}/{{ checkProgress.total }} —
      {{ checkProgress.current }}
    </div>

    <el-table :data="filtered()" v-loading="loading" size="small" height="100%">
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
      <el-table-column label="操作" width="140" fixed="right">
        <template #default="{ row }">
          <el-button link type="primary" @click="openEdit(row)">编辑</el-button>
          <el-button link type="danger" @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
      <template #empty>
        <el-empty description="还没有书源，导入一份试试" />
      </template>
    </el-table>

    <!-- 编辑 -->
    <el-dialog v-model="editDialog" :title="form.id ? '编辑书源' : '新建书源'" width="640">
      <el-form label-width="80px">
        <el-form-item label="名称">
          <el-input v-model="form.name" />
        </el-form-item>
        <el-form-item label="分组">
          <el-input v-model="form.group" />
        </el-form-item>
        <el-form-item label="地址">
          <el-input v-model="form.url" placeholder="bookSourceUrl" />
        </el-form-item>
        <el-form-item label="备注">
          <el-input v-model="form.comment" />
        </el-form-item>
        <el-form-item label="原始JSON">
          <el-input v-model="form.raw" type="textarea" :rows="10" />
        </el-form-item>
        <el-form-item label="启用">
          <el-switch v-model="form.enabled" />
        </el-form-item>
      </el-form>
      <template #footer>
        <el-button @click="editDialog = false">取消</el-button>
        <el-button type="primary" @click="save">保存</el-button>
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
</style>
