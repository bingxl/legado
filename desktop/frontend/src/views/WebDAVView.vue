<script setup lang="ts">
import { onMounted, ref } from "vue";
import { ElMessage } from "element-plus";

import { webdavApi } from "@/api/webdav";
import { systemApi } from "@/api/system";
import { onWebDAVSyncProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";
import type { WebDAVConfigView, WebDAVEntryView } from "@/types";

const config = ref<WebDAVConfigView>({
  url: "",
  username: "",
  hasPassword: false,
  rootPath: "legado-desktop",
  autoSync: false,
  configured: false,
});
const form = ref({
  url: "",
  username: "",
  password: "",
  rootPath: "legado-desktop",
  autoSync: false,
});

const entries = ref<WebDAVEntryView[]>([]);
const loading = ref(false);
const progress = ref<ProgressPayload | null>(null);
const activeTab = ref("config");

async function load() {
  config.value = await webdavApi.getConfig();
  form.value = {
    url: config.value.url,
    username: config.value.username,
    password: "", // 密码永不回显
    rootPath: config.value.rootPath || "legado-desktop",
    autoSync: config.value.autoSync,
  };
}

async function save() {
  try {
    config.value = await webdavApi.saveConfig(
      form.value.url,
      form.value.username,
      form.value.password,
      form.value.rootPath,
      form.value.autoSync,
    );
    form.value.password = "";
    ElMessage.success("配置已保存");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function test() {
  try {
    await webdavApi.test();
    ElMessage.success("连接成功");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function list() {
  loading.value = true;
  try {
    entries.value = await webdavApi.list("");
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    loading.value = false;
  }
}

async function uploadBackup() {
  try {
    const p = await webdavApi.uploadBackup();
    ElMessage.success("备份已上传：" + p.message);
    await list();
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function download(entry: WebDAVEntryView) {
  const dir = await systemApi.openDirectory("选择保存位置");
  if (!dir) return;
  try {
    const path = await webdavApi.downloadBackup(entry.path, dir);
    ElMessage.success("已保存到 " + path);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function remove(entry: WebDAVEntryView) {
  await webdavApi.delete(entry.path);
  await list();
  ElMessage.success("已删除");
}

onMounted(() => {
  load();
  onWebDAVSyncProgress((data) => {
    progress.value = data;
  });
});
</script>

<template>
  <div class="webdav">
    <el-tabs v-model="activeTab" class="tabs">
      <el-tab-pane label="连接配置" name="config">
        <el-form label-width="100px" style="max-width: 520px; padding: 16px">
          <el-form-item label="服务地址">
            <el-input v-model="form.url" placeholder="https://dav.example.com" />
          </el-form-item>
          <el-form-item label="用户名">
            <el-input v-model="form.username" />
          </el-form-item>
          <el-form-item label="密码">
            <el-input
              v-model="form.password"
              type="password"
              show-password
              :placeholder="config.hasPassword ? '留空表示保持不变' : ''"
            />
          </el-form-item>
          <el-form-item label="根目录">
            <el-input v-model="form.rootPath" />
          </el-form-item>
          <el-form-item label="自动同步">
            <el-switch v-model="form.autoSync" />
          </el-form-item>
          <el-form-item>
            <el-button @click="test">测试连接</el-button>
            <el-button type="primary" @click="save">保存</el-button>
          </el-form-item>
        </el-form>
      </el-tab-pane>

      <el-tab-pane label="备份文件" name="files">
        <div class="toolbar">
          <el-button type="primary" @click="uploadBackup">上传备份</el-button>
          <el-button @click="list" :loading="loading">刷新</el-button>
          <div class="spacer" />
          <span v-if="progress" class="progress">{{ progress.message }}</span>
        </div>
        <el-table :data="entries" size="small" v-loading="loading">
          <el-table-column prop="name" label="名称" min-width="220" />
          <el-table-column label="大小" width="110">
            <template #default="{ row }">
              {{ row.size ? (row.size / 1024).toFixed(1) + " KB" : "-" }}
            </template>
          </el-table-column>
          <el-table-column label="操作" width="140">
            <template #default="{ row }">
              <el-button link type="primary" @click="download(row)">下载</el-button>
              <el-button link type="danger" @click="remove(row)">删除</el-button>
            </template>
          </el-table-column>
          <template #empty>
            <el-empty description="还没有备份，先上传一个" />
          </template>
        </el-table>
      </el-tab-pane>
    </el-tabs>
  </div>
</template>

<style scoped>
.webdav {
  padding: 8px 16px;
  height: 100%;
}
.tabs {
  height: 100%;
}
.toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 0;
}
.spacer {
  flex: 1;
}
.progress {
  font-size: 12px;
  color: #9a3412;
}
</style>
