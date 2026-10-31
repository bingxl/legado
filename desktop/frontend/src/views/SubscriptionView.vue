<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import { sourceApi } from "@/api/source";
import { usePlatformStore } from "@/stores/platform";
import type { SubscriptionView } from "@/types";

const platform = usePlatformStore();
const isNarrow = computed(() => platform.isMobile);

const subs = ref<SubscriptionView[]>([]);
const loading = ref(false);
const syncing = ref(false);

// ── 编辑弹窗 ────────────────────────────────────────────────
const dialog = ref(false);
const form = ref({ id: 0, name: "", url: "", enabled: true });

function openCreate() {
  form.value = { id: 0, name: "", url: "", enabled: true };
  dialog.value = true;
}

function openEdit(s: SubscriptionView) {
  form.value = { id: s.id, name: s.name, url: s.url, enabled: s.enabled };
  dialog.value = true;
}

async function submit() {
  const url = form.value.url.trim();
  if (!url) {
    ElMessage.warning("请填写订阅地址");
    return;
  }
  if (!/^https?:\/\//i.test(url)) {
    ElMessage.warning("订阅地址需要以 http:// 或 https:// 开头");
    return;
  }
  await sourceApi.saveSubscription(
    form.value.id,
    form.value.name.trim(),
    url,
    form.value.enabled,
  );
  ElMessage.success("已保存");
  dialog.value = false;
  await load();
}

async function load() {
  loading.value = true;
  try {
    subs.value = await sourceApi.listSubscriptions();
  } finally {
    loading.value = false;
  }
}

async function remove(s: SubscriptionView) {
  try {
    await ElMessageBox.confirm(
      `确定删除订阅「${s.name}」？\n已导入的书源会保留，只是不再随订阅更新。`,
      "删除订阅",
      { confirmButtonText: "删除", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  await sourceApi.deleteSubscription(s.id);
  ElMessage.success("已删除");
  await load();
}

async function toggle(s: SubscriptionView, enabled: boolean) {
  await sourceApi.setSubscriptionEnabled(s.id, enabled);
  await load();
}

/** 刷新单个订阅。 */
async function syncOne(s: SubscriptionView) {
  syncing.value = true;
  try {
    const res = await sourceApi.syncSubscription(s.id);
    if (!res) return;
    ElMessage.success(
      `同步完成：新增 ${res.imported}，更新 ${res.updated}，失败 ${(res.failures ?? []).length}`,
    );
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    syncing.value = false;
  }
}

/** 刷新全部启用订阅。可能几十秒，先给确认再跑。 */
async function syncAll() {
  const enabled = subs.value.filter((s) => s.enabled);
  if (enabled.length === 0) {
    ElMessage.warning("没有启用中的订阅");
    return;
  }
  try {
    await ElMessageBox.confirm(
      `将依次刷新 ${enabled.length} 个订阅，每个都是一次网络请求，可能需要较长时间。是否开始？`,
      "刷新全部订阅",
      { confirmButtonText: "开始刷新", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  syncing.value = true;
  try {
    const results = await sourceApi.syncAllSubscriptions();
    const failed = results.filter((r) => r.error);
    if (failed.length) {
      ElMessage.warning(
        `${failed.length} 个订阅失败：${failed.map((f) => f.subscriptionName).join("、")}`,
      );
    } else {
      ElMessage.success("全部订阅已刷新");
    }
    await load();
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    syncing.value = false;
  }
}

/** 上次同步时间的展示；从未同步过显示「未同步」。 */
function lastSync(s: SubscriptionView): string {
  if (!s.lastSyncAt) return "未同步";
  const d = new Date(s.lastSyncAt);
  if (Number.isNaN(d.getTime())) return "未同步";
  return d.toLocaleString("zh-CN", { hour12: false });
}

onMounted(load);
</script>

<template>
  <div class="sub-view">
    <header class="toolbar">
      <div class="spacer" />
      <el-button :loading="syncing" @click="syncAll">全部刷新</el-button>
      <el-button type="primary" @click="openCreate">新建</el-button>
    </header>

    <div v-loading="loading || syncing" class="list">
      <div v-for="s in subs" :key="s.id" class="sub-card">
        <div class="sub-main">
          <div class="sub-name">{{ s.name }}</div>
          <div class="sub-url">{{ s.url }}</div>
          <div class="sub-meta">上次同步：{{ lastSync(s) }}</div>
        </div>
        <div class="sub-actions">
          <el-switch
            :model-value="s.enabled"
            @change="(v: boolean) => toggle(s, v)"
          />
          <el-button link type="primary" @click="syncOne(s)">刷新</el-button>
          <el-button link type="primary" @click="openEdit(s)">编辑</el-button>
          <el-button link type="danger" @click="remove(s)">删除</el-button>
        </div>
      </div>
      <el-empty
        v-if="!loading && subs.length === 0"
        description="还没有订阅，添加一个远程书源地址"
      />
    </div>

    <el-dialog
      v-model="dialog"
      :title="form.id ? '编辑订阅' : '新建订阅'"
      :fullscreen="isNarrow"
      width="520"
    >
      <el-form label-position="top">
        <el-form-item label="名称">
          <el-input v-model="form.name" placeholder="留空则用地址作为名称" />
        </el-form-item>
        <el-form-item label="订阅地址">
          <el-input
            v-model="form.url"
            placeholder="https://example.com/sources.json"
            spellcheck="false"
          />
        </el-form-item>
        <el-form-item label="启用">
          <el-switch v-model="form.enabled" />
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
.sub-view {
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
.list {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding: 0 16px;
}
.sub-card {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  flex-wrap: wrap;
  padding: 12px 14px;
  margin-bottom: 8px;
  background: #fff;
  border: 1px solid #e5e7eb;
  border-radius: 10px;
}
.sub-main {
  min-width: 0;
  flex: 1;
}
.sub-name {
  font-size: 14px;
  font-weight: 600;
  color: #1f2328;
  word-break: break-all;
}
/* 地址可能很长但不重要，截断即可——完整地址在编辑弹窗里看 */
.sub-url {
  margin-top: 2px;
  font-size: 12px;
  color: #6b7280;
  word-break: break-all;
}
.sub-meta {
  margin-top: 4px;
  font-size: 12px;
  color: #9ca3af;
}
.sub-actions {
  display: flex;
  align-items: center;
  gap: 4px;
  flex: none;
}

@media (max-width: 640px) {
  .toolbar,
  .list {
    padding-left: 12px;
    padding-right: 12px;
  }
  .sub-actions {
    width: 100%;
    justify-content: flex-end;
  }
}
</style>
