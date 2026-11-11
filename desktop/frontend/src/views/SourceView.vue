<script setup lang="ts">
/**
 * 书源管理页。
 *
 * 结构对齐 Legado 原生的 BookSourceActivity：
 *   顶部   搜索框（支持 group:分组 / 启用 / 禁用 / 需要登录 / 无分组 /
 *          启用发现 / 禁用发现）+ 排序菜单 + 分组菜单 + 更多菜单
 *   列表   每行：复选框 · 名称+分组 · 发现圆点 · 启用开关 · 编辑 · 更多
 *          校验时行内显示「成功 / 失败：原因」
 *   底部   选中后出现批量操作栏（全选/反选/区间选择/删除/批量菜单）
 *
 * 与原生的差异（都是桌面端该有的）：
 *  - 保留手动刷新与增量分页渲染（上千书源一次性挂 DOM 会卡）；
 *  - 校验结果除了行内消息，结束时汇总一次（原生靠 snackbar 逐条刷）；
 *  - 拖拽排序用 HTML5 draggable，逻辑与原生的 ItemTouchHelper 一致：
 *    仅「手动排序 + 未按域名分组」时可拖，松手后提交整段顺序。
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { sourceApi } from "@/api/source";
import { systemApi, rawFileURL } from "@/api/system";
import { useSourcesStore } from "@/stores/sources";
import { useSourceCheckStore } from "@/stores/sourceCheck";
import type { SourceView as SourceItem } from "@/types";
import SourceRow from "@/components/source/SourceRow.vue";
import SourceGroupDialog from "@/components/source/SourceGroupDialog.vue";
import SourceLoginDialog from "@/components/SourceLoginDialog.vue";
import {
  FILTER_PRESETS,
  GROUP_PREFIX,
  SORT_OPTIONS,
  filterSources,
  sortLabel,
  sortSources,
  sourceHost,
  splitGroups,
  type SourceSortKey,
} from "@/utils/sourceList";

const store = useSourcesStore();
const check = useSourceCheckStore();
const router = useRouter();

// ── 搜索 / 排序 / 分组 ─────────────────────────────────────
const keyword = ref("");
const sort = ref<SourceSortKey>(
  (localStorage.getItem("legado.sourceSort") as SourceSortKey) || "manual",
);
const ascending = ref(localStorage.getItem("legado.sourceSortAsc") !== "0");
const groupByHost = ref(localStorage.getItem("legado.sourceGroupByHost") === "1");

watch([sort, ascending, groupByHost], () => {
  localStorage.setItem("legado.sourceSort", sort.value);
  localStorage.setItem("legado.sourceSortAsc", ascending.value ? "1" : "0");
  localStorage.setItem("legado.sourceGroupByHost", groupByHost.value ? "1" : "0");
});

/** 手动排序且未按域名分组时才能拖（与原生 isCanDrag 一致）。 */
const canDrag = computed(
  () => sort.value === "manual" && !groupByHost.value && !keyword.value.trim(),
);

function setSort(key: string) {
  if (key === "toggle-dir") {
    ascending.value = !ascending.value;
    return;
  }
  sort.value = key as SourceSortKey;
  ascending.value = true;
}

// ── 列表 ────────────────────────────────────────────────────
const filtered = computed(() => filterSources(store.sources, keyword.value));

/** 拖拽后的本地顺序（id 序列）；为空表示沿用排序结果。 */
const localOrder = ref<number[] | null>(null);

const ordered = computed(() => {
  const sorted = sortSources(filtered.value, sort.value, ascending.value, groupByHost.value);
  if (!localOrder.value) return sorted;
  const pos = new Map(localOrder.value.map((id, i) => [id, i]));
  return [...sorted].sort(
    (a, b) => (pos.get(a.id) ?? Number.MAX_SAFE_INTEGER) - (pos.get(b.id) ?? Number.MAX_SAFE_INTEGER),
  );
});

// 筛选/排序变化时丢弃本地拖拽顺序：那是一份「旧视图」的快照，套到新视图上会错位。
// 同时把增量渲染回退到第一页并滚回顶部——只重置 visibleCount 是不够的：
// 用户可能刚滚到底部，容器 scrollTop 仍在底部，列表一变短就立刻触发
// 「触底追加」，搜索完看到的还是几百行（旧实现踩过这个坑）。
watch([keyword, sort, ascending, groupByHost], async () => {
  localOrder.value = null;
  visibleCount.value = PAGE_SIZE;
  await nextTick();
  if (scrollEl.value) scrollEl.value.scrollTop = 0;
});

// ── 增量渲染 ────────────────────────────────────────────────
// 原生有 RecyclerView 的复用；DOM 列表没有，上千行一次性挂载会明显卡顿。
// 首屏 300 行，滚动触底追加下一页。
const PAGE_SIZE = 300;
const visibleCount = ref(PAGE_SIZE);
const scrollEl = ref<HTMLElement | null>(null);

const visibleRows = computed(() => ordered.value.slice(0, visibleCount.value));

/** 渲染项：按域名分组时插入 host 分组头。 */
const displayItems = computed(() => {
  const items: (
    | { kind: "host"; key: string; host: string }
    | { kind: "row"; key: string; row: SourceItem; index: number }
  )[] = [];
  let lastHost = "";
  visibleRows.value.forEach((row, index) => {
    if (groupByHost.value) {
      const h = sourceHost(row.url);
      if (h !== lastHost) {
        items.push({ kind: "host", key: `host-${h}-${index}`, host: h });
        lastHost = h;
      }
    }
    items.push({ kind: "row", key: `row-${row.id}`, row, index });
  });
  return items;
});

function onScroll() {
  const el = scrollEl.value;
  if (!el) return;
  if (el.scrollTop + el.clientHeight >= el.scrollHeight - 120) {
    if (visibleCount.value < ordered.value.length) {
      visibleCount.value = Math.min(visibleCount.value + PAGE_SIZE, ordered.value.length);
    }
  }
}

// ── 选择 ────────────────────────────────────────────────────
const selected = ref<Set<number>>(new Set());
const selectedIds = computed(() => [...selected.value]);
const allSelected = computed(
  () => visibleRows.value.length > 0 && visibleRows.value.every((r) => selected.value.has(r.id)),
);

function toggleSelect(row: SourceItem, v?: boolean) {
  const next = new Set(selected.value);
  const on = v ?? !next.has(row.id);
  if (on) next.add(row.id);
  else next.delete(row.id);
  selected.value = next;
}

function toggleSelectAll(v: boolean) {
  if (v) {
    selected.value = new Set(visibleRows.value.map((r) => r.id));
  } else {
    selected.value = new Set();
  }
}

/** 反选（只作用于当前可见行）。 */
function invertSelection() {
  const next = new Set<number>();
  for (const r of visibleRows.value) {
    if (!selected.value.has(r.id)) next.add(r.id);
  }
  selected.value = next;
}

/** 区间选择：把第一个与最后一个选中项之间的所有行都选上（原生 checkSelectedInterval）。 */
function selectInterval() {
  const idx = visibleRows.value
    .map((r, i) => (selected.value.has(r.id) ? i : -1))
    .filter((i) => i >= 0);
  if (idx.length < 2) {
    ElMessage.info("请先选中至少两个书源，再使用区间选择");
    return;
  }
  const next = new Set(selected.value);
  for (let i = idx[0]; i <= idx[idx.length - 1]; i++) next.add(visibleRows.value[i].id);
  selected.value = next;
}

// 筛选后要清掉「已不可见」的选中项，否则批量操作会作用到看不见的源上。
watch([keyword], () => {
  const alive = new Set(store.sources.map((s) => s.id));
  selected.value = new Set([...selected.value].filter((id) => alive.has(id)));
});

// ── 拖拽排序 ────────────────────────────────────────────────
const dragIndex = ref(-1);

function onDragStart(e: DragEvent, index: number) {
  if (!canDrag.value) return;
  dragIndex.value = index;
  if (e.dataTransfer) {
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", String(index));
  }
}

function onDragOver(e: DragEvent, index: number) {
  if (dragIndex.value < 0 || index === dragIndex.value) return;
  e.preventDefault();
  const ids = ordered.value.map((r) => r.id);
  const [moved] = ids.splice(dragIndex.value, 1);
  ids.splice(index, 0, moved);
  localOrder.value = ids;
  dragIndex.value = index;
}

async function onDragEnd() {
  if (dragIndex.value < 0) return;
  dragIndex.value = -1;
  const ids = ordered.value.map((r) => r.id);
  localOrder.value = null;
  try {
    await sourceApi.reorder(ids);
    // 就地更新 order：否则下一次排序（比如切回「手动」）会回到旧顺序。
    ids.forEach((id, i) => store.patch(id, { order: i }));
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 单行操作 ────────────────────────────────────────────────
function openCreate() {
  void router.push("/sources/new");
}
function openEdit(row: SourceItem) {
  void router.push(`/sources/${row.id}/edit`);
}
function openDebug(row: SourceItem) {
  void router.push(`/sources/${row.id}/edit?tab=debug`);
}

async function setEnabled(row: SourceItem, enabled: boolean) {
  try {
    await sourceApi.setEnabled(row.id, enabled);
    store.patch(row.id, { enabled });
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function onRowCommand(cmd: string, row: SourceItem) {
  switch (cmd) {
    case "top":
    case "bottom":
      await moveRow(row, cmd === "top");
      break;
    case "login":
      openLogin(row);
      break;
    case "search":
      void router.push(`/search?sourceId=${row.id}&sourceName=${encodeURIComponent(row.name)}`);
      break;
    case "debug":
      openDebug(row);
      break;
    case "toggle-explore":
      await setExplore([row.id], !row.enabledExplore);
      break;
    case "delete":
      await deleteOne(row);
      break;
  }
}

async function moveRow(row: SourceItem, toTop: boolean) {
  // 降序视图里「置顶」在视觉上等于置底，原生也是这样处理的。
  const up = toTop === ascending.value;
  try {
    await (up ? sourceApi.moveTop([row.id]) : sourceApi.moveBottom([row.id]));
    await store.refresh();
    ElMessage.success(up ? "已置顶" : "已置底");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function deleteOne(row: SourceItem) {
  try {
    await ElMessageBox.confirm(`删除书源「${row.name}」？`, "删除书源", {
      confirmButtonText: "删除",
      cancelButtonText: "取消",
      type: "warning",
    });
  } catch {
    return;
  }
  try {
    await sourceApi.delete(row.id);
    store.removeLocal(row.id);
    selected.value.delete(row.id);
    selected.value = new Set(selected.value);
    ElMessage.success("已删除");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function setExplore(ids: number[], enabled: boolean) {
  try {
    await sourceApi.setEnabledExploreBatch(ids, enabled);
    store.patchMany(ids, { enabledExplore: enabled });
    ElMessage.success(enabled ? "已启用发现" : "已禁用发现");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 登录 ────────────────────────────────────────────────────
const loginDialog = ref(false);
const loginTarget = ref<SourceItem | null>(null);
function openLogin(row: SourceItem) {
  loginTarget.value = row;
  loginDialog.value = true;
}

// ── 分组 ────────────────────────────────────────────────────
const groupDialog = ref(false);

/** 分组菜单命令：预设筛选词、具体分组、分组管理。 */
async function onGroupCommand(cmd: string) {
  if (cmd === "manage") {
    groupDialog.value = true;
    return;
  }
  if (cmd.startsWith("preset:")) {
    keyword.value = cmd.slice("preset:".length);
    return;
  }
  if (cmd.startsWith("group:")) {
    keyword.value = `${GROUP_PREFIX}${cmd.slice("group:".length)}`;
    return;
  }
  if (cmd === "clear-filter") {
    keyword.value = "";
  }
}

async function batchGroup(add: boolean): Promise<boolean> {
  if (!selectedIds.value.length) return false;
  const names = store.groups.map((g) => g.name).join(" / ") || "（还没有分组）";
  try {
    const { value } = await ElMessageBox.prompt(
      add
        ? `把选中的 ${selectedIds.value.length} 个书源加入哪个分组？可输入新名字。现有分组：${names}`
        : `把选中的 ${selectedIds.value.length} 个书源从哪个分组移出？现有分组：${names}`,
      add ? "加入分组" : "移出分组",
      { confirmButtonText: "确定", cancelButtonText: "取消", inputValue: "" },
    );
    const name = (value || "").trim();
    if (!name) return false;
    const ids = selectedIds.value;
    await (add ? sourceApi.addToGroup(ids, name) : sourceApi.removeFromGroup(ids, name));
    await Promise.all([store.refresh(), store.refreshGroups()]);
    ElMessage.success(add ? `已加入分组「${name}」` : `已移出分组「${name}」`);
    return true;
  } catch (e) {
    if (e !== "cancel" && e !== "close") ElMessage.error((e as Error).message);
    return false;
  }
}

// ── 校验 ────────────────────────────────────────────────────
async function runCheck(ids: number[]) {
  let targets = ids;
  if (!targets.length) {
    targets = filtered.value.filter((s) => s.enabled).map((s) => s.id);
  }
  if (!targets.length) {
    ElMessage.warning("没有可校验的书源（未选中任何项，且当前列表里没有启用的书源）");
    return;
  }
  let kw = check.keyword;
  try {
    const { value } = await ElMessageBox.prompt(
      `将校验 ${targets.length} 个书源。搜索校验用的关键词（部分书源只在特定词下才返回结果）：`,
      "校验书源",
      { confirmButtonText: "开始校验", cancelButtonText: "取消", inputValue: kw },
    );
    kw = (value || "").trim();
  } catch {
    return;
  }
  check.setKeyword(kw);
  check.begin(targets.length);
  try {
    const res = (await sourceApi.validateWith(targets, kw)) ?? [];
    const bad = res.filter((r) => !r.ok).length;
    if (bad > 0) {
      ElMessage.warning(`校验完成：${res.length - bad} 个通过，${bad} 个有问题`);
    } else {
      ElMessage.success(`校验完成：${res.length} 个书源全部通过`);
    }
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    check.finish();
  }
}

// ── 导入 / 导出 ─────────────────────────────────────────────
async function importFromFile() {
  const paths = await systemApi.openSourceFile();
  if (!paths || paths.length === 0) return;
  try {
    const resp = await fetch(rawFileURL(paths[0]));
    if (!resp.ok) throw new Error("无法读取文件");
    const res = await sourceApi.import(await resp.text(), true);
    if (!res) return;
    ElMessage.success(
      `导入完成：新增 ${res.imported}，更新 ${res.updated}，失败 ${(res.failures ?? []).length}`,
    );
    await Promise.all([store.refresh(), store.refreshGroups()]);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

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
    await Promise.all([store.refresh(), store.refreshGroups()]);
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    urlLoading.value = false;
  }
}

async function exportSources(ids: number[] = []) {
  try {
    const json = await sourceApi.export(ids);
    const dest = await systemApi.saveFile("导出书源", "bookSources.json");
    if (!dest) return;
    await systemApi.saveTextFile(dest, json);
    ElMessage.success(`已导出到 ${dest}`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 分享选中：把书源 JSON 复制到剪贴板（桌面端没有系统分享面板）。 */
async function shareSelected() {
  try {
    const json = await sourceApi.export(selectedIds.value);
    await navigator.clipboard.writeText(json);
    ElMessage.success("已复制书源 JSON 到剪贴板");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 批量操作 ────────────────────────────────────────────────
/**
 * 批量改动做完就退出多选（原生 finishActionMode 的行为）。
 *
 * 留着选中态的话，用户看到「已禁用」还以为要再点一次才生效；
 * 而且列表已经变了，旧选中集合容易和新列表对不上。
 */
function exitSelection(): void {
  selected.value = new Set();
}

async function batchCommand(cmd: string) {
  const ids = selectedIds.value;
  if (!ids.length) return;
  switch (cmd) {
    case "enable":
    case "disable": {
      const on = cmd === "enable";
      await sourceApi.setEnabledBatch(ids, on);
      store.patchMany(ids, { enabled: on });
      ElMessage.success(on ? "已启用" : "已禁用");
      exitSelection();
      break;
    }
    case "enable-explore":
      await setExplore(ids, true);
      exitSelection();
      break;
    case "disable-explore":
      await setExplore(ids, false);
      exitSelection();
      break;
    case "add-group":
      if (await batchGroup(true)) exitSelection();
      break;
    case "remove-group":
      if (await batchGroup(false)) exitSelection();
      break;
    case "top":
    case "bottom": {
      const up = (cmd === "top") === ascending.value;
      await (up ? sourceApi.moveTop(ids) : sourceApi.moveBottom(ids));
      await store.refresh();
      ElMessage.success(up ? "已置顶" : "已置底");
      exitSelection();
      break;
    }
    case "export":
      await exportSources(ids);
      break;
    case "share":
      await shareSelected();
      break;
    case "check":
      await runCheck(ids);
      break;
  }
}

async function deleteSelected() {
  const ids = selectedIds.value;
  const names = store.sources
    .filter((s) => ids.includes(s.id))
    .slice(0, 3)
    .map((s) => s.name)
    .join("、");
  try {
    await ElMessageBox.confirm(
      `删除选中的 ${ids.length} 个书源？${names ? `（含 ${names}${ids.length > 3 ? " 等" : ""}）` : ""}`,
      "删除书源",
      { confirmButtonText: "删除", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  try {
    await sourceApi.deleteBatch(ids);
    store.removeLocalMany(ids);
    selected.value = new Set();
    ElMessage.success("已删除");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

// ── 更多菜单 ────────────────────────────────────────────────
const helpDialog = ref(false);

async function onMoreCommand(cmd: string) {
  switch (cmd) {
    case "create":
      openCreate();
      break;
    case "import-file":
      await importFromFile();
      break;
    case "import-url":
      urlDialog.value = true;
      break;
    case "groups":
      groupDialog.value = true;
      break;
    case "group-by-host":
      groupByHost.value = !groupByHost.value;
      break;
    case "check-all":
      await runCheck([]);
      break;
    case "export-all":
      await exportSources([]);
      break;
    case "help":
      helpDialog.value = true;
      break;
  }
}

// ── 生命周期 ────────────────────────────────────────────────
onMounted(() => {
  check.attach();
  void store.ensureLoaded();
  scrollEl.value?.addEventListener("scroll", onScroll, { passive: true });
});

onBeforeUnmount(() => {
  scrollEl.value?.removeEventListener("scroll", onScroll);
});

/** 当前筛选的中文描述（顶部提示条用）。 */
const filterHint = computed(() => {
  const k = keyword.value.trim();
  if (!k) return "";
  if (k.startsWith(GROUP_PREFIX)) return `分组：${k.slice(GROUP_PREFIX.length)}`;
  return `筛选：${k}`;
});

const sortText = computed(
  () => `${sortLabel(sort.value)}${ascending.value ? " ↑" : " ↓"}`,
);
</script>

<template>
  <div class="source-view">
    <!-- ── 工具条 ────────────────────────────────────────── -->
    <header class="toolbar">
      <el-input
        v-model="keyword"
        class="kw"
        placeholder="搜索书源 / group:分组 / 启用 / 禁用 / 需要登录 / 无分组"
        clearable
        data-role="source-search"
      />

      <el-dropdown trigger="click" @command="setSort">
        <el-button data-role="sort">
          {{ sortText }}
        </el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="toggle-dir">
              {{ ascending ? "改为降序" : "改为升序" }}
            </el-dropdown-item>
            <el-dropdown-item
              v-for="o in SORT_OPTIONS"
              :key="o.key"
              :command="o.key"
              :class="{ 'is-active': sort === o.key }"
              divided
            >
              {{ o.label }}
            </el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>

      <el-dropdown trigger="click" @command="onGroupCommand">
        <el-button data-role="group">分组</el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="manage">分组管理…</el-dropdown-item>
            <el-dropdown-item command="clear-filter" divided :disabled="!filterHint">
              清除筛选
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.enabled}`">
              {{ FILTER_PRESETS.enabled }}
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.disabled}`">
              {{ FILTER_PRESETS.disabled }}
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.needLogin}`">
              {{ FILTER_PRESETS.needLogin }}
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.noGroup}`">
              {{ FILTER_PRESETS.noGroup }}
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.enabledExplore}`">
              {{ FILTER_PRESETS.enabledExplore }}
            </el-dropdown-item>
            <el-dropdown-item :command="`preset:${FILTER_PRESETS.disabledExplore}`">
              {{ FILTER_PRESETS.disabledExplore }}
            </el-dropdown-item>
            <el-dropdown-item
              v-for="g in store.groups"
              :key="g.name"
              :command="`group:${g.name}`"
              divided
            >
              {{ g.name }}（{{ g.count }}）
            </el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>

      <div class="spacer" />

      <el-button @click="store.refresh()" :loading="store.loading">刷新</el-button>

      <el-dropdown trigger="click" @command="onMoreCommand">
        <el-button data-role="more">更多</el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="create">新建书源</el-dropdown-item>
            <el-dropdown-item command="import-file" divided>从文件导入</el-dropdown-item>
            <el-dropdown-item command="import-url">从 URL 导入</el-dropdown-item>
            <el-dropdown-item command="groups" divided>分组管理…</el-dropdown-item>
            <el-dropdown-item command="group-by-host">
              {{ groupByHost ? "✓ " : "" }}按域名分组
            </el-dropdown-item>
            <el-dropdown-item command="check-all" divided>校验启用书源…</el-dropdown-item>
            <el-dropdown-item command="export-all">导出全部</el-dropdown-item>
            <el-dropdown-item command="help" divided>帮助</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>

      <el-button type="primary" @click="openCreate" data-role="create">新建</el-button>
    </header>

    <!-- ── 筛选 / 校验状态 ───────────────────────────────── -->
    <div v-if="filterHint" class="filter-bar">
      <span>{{ filterHint }}</span>
      <span class="filter-count">{{ filtered.length }} 个书源</span>
      <el-button link size="small" @click="keyword = ''">清除</el-button>
    </div>
    <div v-if="check.running || check.total > 0" class="progress">
      <template v-if="check.running">
        校验中 {{ check.done }}/{{ check.total }}
        <span v-if="check.current"> — {{ check.current }}</span>
      </template>
      <template v-else>校验完成，共 {{ check.total }} 个书源</template>
      <el-button v-if="!check.running" link size="small" @click="check.clear()">
        清除消息
      </el-button>
    </div>

    <!-- ── 列表 ───────────────────────────────────────────── -->
    <div ref="scrollEl" class="source-scroll r-scroll-x" v-loading="store.loading">
      <div v-if="ordered.length === 0" class="empty">
        <el-empty
          :description="
            keyword ? '没有匹配的书源' : '还没有书源，导入一份试试'
          "
        />
      </div>

      <template v-for="item in displayItems" :key="item.key">
        <div v-if="item.kind === 'host'" class="host-head">{{ item.host }}</div>
        <SourceRow
          v-else
          :source="item.row"
          :selected="selected.has(item.row.id)"
          :message="check.messages[item.row.id]"
          :checking="check.running"
          :can-drag="canDrag"
          :show-top-bottom="sort === 'manual' && !groupByHost"
          @select="(v: boolean) => toggleSelect(item.row, v)"
          @edit="openEdit(item.row)"
          @toggle-enabled="(v: boolean) => setEnabled(item.row, v)"
          @command="(c: string) => onRowCommand(c, item.row)"
          @dragstart="onDragStart($event as DragEvent, item.index)"
          @dragover="onDragOver($event as DragEvent, item.index)"
          @dragend="onDragEnd"
        />
      </template>

      <div v-if="ordered.length > PAGE_SIZE" class="table-foot">
        <template v-if="visibleRows.length < ordered.length">
          已显示 {{ visibleRows.length }} / 共 {{ ordered.length }} 条，滑到底部自动加载下一页
        </template>
        <template v-else>已显示全部 {{ ordered.length }} 条</template>
      </div>
    </div>

    <!-- ── 批量操作栏 ─────────────────────────────────────── -->
    <footer v-if="selected.size > 0" class="sel-bar">
      <el-checkbox
        :model-value="allSelected"
        @change="(v: string | number | boolean) => toggleSelectAll(Boolean(v))"
      >
        全选
      </el-checkbox>
      <span class="sel-count">已选 {{ selected.size }} / {{ visibleRows.length }}</span>
      <el-button link @click="invertSelection">反选</el-button>
      <el-button link @click="selectInterval">区间选择</el-button>
      <el-button link @click="selected = new Set()">取消选择</el-button>
      <div class="spacer" />
      <el-button type="danger" @click="deleteSelected">删除</el-button>
      <el-dropdown trigger="click" @command="batchCommand">
        <el-button>更多操作</el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="enable">启用</el-dropdown-item>
            <el-dropdown-item command="disable">禁用</el-dropdown-item>
            <el-dropdown-item command="enable-explore" divided>启用发现</el-dropdown-item>
            <el-dropdown-item command="disable-explore">禁用发现</el-dropdown-item>
            <el-dropdown-item command="add-group" divided>加入分组</el-dropdown-item>
            <el-dropdown-item command="remove-group">移出分组</el-dropdown-item>
            <el-dropdown-item command="top" divided>置顶</el-dropdown-item>
            <el-dropdown-item command="bottom">置底</el-dropdown-item>
            <el-dropdown-item command="check" divided>校验选中</el-dropdown-item>
            <el-dropdown-item command="export">导出选中</el-dropdown-item>
            <el-dropdown-item command="share">复制 JSON</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
    </footer>

    <!-- ── 对话框 ─────────────────────────────────────────── -->
    <SourceLoginDialog
      v-model="loginDialog"
      :source-id="loginTarget?.id ?? 0"
      :source-name="loginTarget?.name"
      @changed="store.refresh()"
    />

    <SourceGroupDialog v-model="groupDialog" />

    <el-dialog v-model="urlDialog" title="从 URL 导入书源" width="560" append-to-body>
      <el-input
        v-model="urlInput"
        placeholder="https://example.com/bookSources.json"
        clearable
        @keyup.enter="importFromUrl"
      />
      <p class="hint">
        地址指向一份书源 JSON 文件，可包含多个书源；也兼容 Legado 备份文件（含 data 字段）。
      </p>
      <el-checkbox v-model="urlOverwrite">覆盖相同 bookSourceUrl 的书源</el-checkbox>
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

    <el-dialog v-model="helpDialog" title="书源管理" width="560" append-to-body>
      <div class="help">
        <h4>筛选</h4>
        <ul>
          <li>搜索框按名称 / 分组 / 地址模糊匹配</li>
          <li><code>group:分组名</code> 只看某个分组</li>
          <li>
            <code>启用</code> <code>禁用</code> <code>需要登录</code>
            <code>无分组</code> <code>启用发现</code> <code>禁用发现</code>
            是内置筛选词
          </li>
        </ul>
        <h4>排序</h4>
        <ul>
          <li>手动排序：按自定义顺序，可直接拖拽行调整</li>
          <li>智能排序：按书源权重</li>
          <li>按更新时间：升序时最新的在前（与原生一致）</li>
        </ul>
        <h4>批量操作</h4>
        <ul>
          <li>勾选任意行后底部出现操作栏：全选 / 反选 / 区间选择</li>
          <li>批量启停、批量启停发现、加入/移出分组、置顶置底、导出、校验</li>
        </ul>
        <h4>校验</h4>
        <p>
          校验会在每行显示「成功 / 失败：原因」。搜索校验的关键词可以在开始前修改——
          部分书源只在特定关键词下才返回结果。
        </p>
      </div>
      <template #footer>
        <el-button @click="helpDialog = false">关闭</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.source-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  min-width: 0;
  padding: 0 0 var(--r-pad-sm);
}
.toolbar {
  flex: none;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
}
.kw {
  width: min(100%, 320px);
  max-width: 100%;
  min-width: 0;
  flex: none;
}
.spacer {
  flex: 1;
  min-width: 0;
}
.filter-bar {
  flex: none;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  font-size: 12px;
  color: var(--el-color-primary);
  background: var(--el-color-primary-light-9);
}
.filter-count {
  color: var(--el-text-color-secondary);
}
.progress {
  flex: none;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  font-size: 13px;
  color: #9a3412;
  background: #fff7ed;
}
.source-scroll {
  flex: 1;
  min-height: 0;
  min-width: 0;
  overflow-y: auto;
  border-top: 1px solid var(--el-border-color-lighter);
}
.empty {
  padding: 40px 0;
}
.host-head {
  padding: var(--r-pad-sm) var(--r-pad);
  font-size: 12px;
  font-weight: 600;
  color: var(--el-color-primary);
  background: var(--el-fill-color-light);
  position: sticky;
  top: 0;
  z-index: 1;
}
.table-foot {
  padding: var(--r-pad-sm) var(--r-pad);
  font-size: 12px;
  color: var(--el-text-color-secondary);
}
.sel-bar {
  flex: none;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  border-top: 1px solid var(--el-border-color);
  background: var(--el-bg-color);
  box-shadow: 0 -2px 8px rgb(0 0 0 / 6%);
}
.sel-count {
  font-size: 13px;
  color: var(--el-text-color-regular);
}
.hint {
  margin: 8px 0;
  font-size: 12px;
  line-height: 1.5;
  color: var(--el-text-color-secondary);
}
.help {
  max-height: 56vh;
  overflow-y: auto;
  min-width: 0;
  font-size: 13px;
  line-height: 1.7;
}
.help h4 {
  margin: 10px 0 4px;
  font-size: 13px;
}
.help ul {
  margin: 0;
  padding-left: 18px;
}
.help code {
  background: var(--el-fill-color-light);
  padding: 0 3px;
  border-radius: 3px;
  font-size: 12px;
}

/* 窄屏：搜索框占满一行，按钮紧随其后；批量栏允许换行 */
@media (max-width: 640px) {
  /*
   * 必须允许换行：窄屏下搜索框的 flex-basis 是 100%，不给 wrap 的话
   * 它只能被挤成一条几像素的缝（右侧按钮 flex:none 不让位），
   * 搜索框看起来就是个空的小方块。
   */
  .toolbar {
    padding: var(--r-pad-sm);
    flex-wrap: wrap;
  }
  .kw {
    width: 100%;
    flex: 1 1 100%;
  }
  /* 桌面靠这个弹性块把按钮推到右边；窄屏上留着它反而把「新建」挤到第三行。 */
  .spacer {
    display: none;
  }
  .sel-bar {
    flex-wrap: wrap;
    gap: var(--r-gap-sm);
    padding: var(--r-pad-sm);
  }
  .host-head {
    padding: var(--r-pad-sm);
  }
}
</style>
