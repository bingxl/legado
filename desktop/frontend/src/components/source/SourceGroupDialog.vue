<script setup lang="ts">
/**
 * 分组管理对话框（对应原生 GroupManageDialog）。
 *
 * 分组在 Legado 里不是独立实体，只是书源上的一个字段，所以三个操作的语义是：
 *  - 新建：把所有「无分组」的书源归入新组（不存在空分组）；
 *  - 改名：批量替换书源上的组名；
 *  - 删除：只把组名从书源上摘掉，书源本身保留。
 * 界面上必须把这点说清楚，否则用户会以为删除分组会连带删掉书源。
 */
import { computed, ref } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";

import { sourceApi } from "@/api/source";
import { useSourcesStore } from "@/stores/sources";

const visible = defineModel<boolean>({ required: true });
const store = useSourcesStore();

const busy = ref(false);
const filter = ref("");

const list = computed(() => {
  const k = filter.value.trim().toLowerCase();
  if (!k) return store.groups;
  return store.groups.filter((g) => g.name.toLowerCase().includes(k));
});

/** 无分组书源数量：新建分组时提示「将归入 N 个书源」。 */
const noGroupCount = computed(
  () => store.sources.filter((s) => !s.group || !s.group.trim()).length,
);

async function addGroup() {
  try {
    const { value } = await ElMessageBox.prompt(
      `分组名。所有「无分组」的书源（当前 ${noGroupCount.value} 个）会归入新分组——` +
        `Legado 里没有「空分组」这个概念。`,
      "新建分组",
      { confirmButtonText: "创建", cancelButtonText: "取消", inputValue: "" },
    );
    const name = (value || "").trim();
    if (!name) return;
    busy.value = true;
    const n = await sourceApi.addGroupToNoGroup(name);
    await Promise.all([store.refresh(), store.refreshGroups()]);
    ElMessage.success(n > 0 ? `已创建分组「${name}」，归入 ${n} 个书源` : `已创建分组「${name}」`);
  } catch (e) {
    if (e !== "cancel" && e !== "close") ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}

async function rename(oldName: string) {
  try {
    const { value } = await ElMessageBox.prompt(
      `把分组「${oldName}」改名为（留空表示清空这些书源的分组）：`,
      "重命名分组",
      { confirmButtonText: "保存", cancelButtonText: "取消", inputValue: oldName },
    );
    const next = (value || "").trim();
    if (next === oldName) return;
    busy.value = true;
    await sourceApi.renameGroup(oldName, next);
    await Promise.all([store.refresh(), store.refreshGroups()]);
    ElMessage.success("已更新分组");
  } catch (e) {
    if (e !== "cancel" && e !== "close") ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}

async function remove(name: string, count: number) {
  try {
    await ElMessageBox.confirm(
      `删除分组「${name}」？组内 ${count} 个书源会被保留，只是不再属于这个分组。`,
      "删除分组",
      { confirmButtonText: "删除", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  busy.value = true;
  try {
    await sourceApi.deleteGroup(name);
    await Promise.all([store.refresh(), store.refreshGroups()]);
    ElMessage.success("已删除分组");
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <el-dialog v-model="visible" title="分组管理" width="520" append-to-body>
    <div class="gm-bar">
      <el-input v-model="filter" placeholder="筛选分组" clearable size="small" />
      <el-button size="small" type="primary" :loading="busy" @click="addGroup">
        新建分组
      </el-button>
    </div>

    <div v-if="list.length === 0" class="gm-empty">
      {{ filter ? "没有匹配的分组" : "还没有任何分组" }}
    </div>
    <ul v-else class="gm-list">
      <li v-for="g in list" :key="g.name" class="gm-item">
        <span class="gm-name">{{ g.name }}</span>
        <span class="gm-count">{{ g.count }} 个书源</span>
        <span class="gm-actions">
          <el-button link type="primary" size="small" @click="rename(g.name)">
            改名
          </el-button>
          <el-button
            link
            type="danger"
            size="small"
            @click="remove(g.name, g.count)"
          >
            删除
          </el-button>
        </span>
      </li>
    </ul>

    <template #footer>
      <span class="gm-tip">
        删除分组不会删除书源；「新建分组」会收拢所有无分组的书源。
      </span>
      <el-button @click="visible = false">关闭</el-button>
    </template>
  </el-dialog>
</template>

<style scoped>
.gm-bar {
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
  margin-bottom: var(--r-pad-sm);
}
.gm-bar :deep(.el-input) {
  flex: 1 1 140px;
  min-width: 0;
  max-width: 100%;
}
.gm-empty {
  padding: var(--r-pad) 0;
  min-width: 0;
  text-align: center;
  color: var(--el-text-color-secondary);
  font-size: 13px;
}
.gm-list {
  list-style: none;
  margin: 0;
  padding: 0;
  min-width: 0;
  max-width: 100%;
  max-height: 50vh;
  overflow-y: auto;
}
.gm-item {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  max-width: 100%;
  padding: var(--r-pad-sm) var(--r-gap-sm);
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.gm-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 14px;
}
.gm-count {
  flex: none;
  min-width: 0;
  font-size: 12px;
  color: var(--el-text-color-secondary);
}
.gm-actions {
  flex: none;
  display: inline-flex;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.gm-tip {
  float: none;
  margin-right: auto;
  min-width: 0;
  max-width: 100%;
  font-size: 12px;
  color: var(--el-text-color-secondary);
  line-height: 1.5;
  text-align: left;
}
:deep(.el-dialog__footer) {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: flex-end;
  gap: var(--r-gap-sm);
}

@media (max-width: 640px) {
  .gm-bar :deep(.el-input) {
    flex: 1 1 100%;
  }
}
</style>
