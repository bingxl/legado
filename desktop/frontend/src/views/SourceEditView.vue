<script setup lang="ts">
/**
 * 书源编辑页。
 *
 * 布局参考 Legado 官方 Web 编辑器（modules/web 的 SourceEditor）：
 * 左侧分组表单、中间一列动作按钮、右侧「JSON / 调试 / 帮助」工具页。
 * 这套三栏结构是有道理的——书源编辑本质上是「改规则 → 立刻跑一遍 → 看哪条没命中」
 * 的循环，把表单和调试放在同一屏，比来回弹窗快得多。
 *
 * 与参考实现的差异：
 * - 调试面板支持**未保存的草稿**（后端接受 raw），改完规则不用先保存；
 * - 没有「推送/拉取源」这类跨端同步按钮，桌面端本身就是数据源；
 * - 表单字段说明以 tooltip 形式给，不占版面。
 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { onBeforeRouteLeave, useRoute, useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import SourceFormTabs from "@/components/source/SourceFormTabs.vue";
import SourceDebugPanel from "@/components/source/SourceDebugPanel.vue";
import SourceLoginDialog from "@/components/SourceLoginDialog.vue";
import { useSourceEditStore } from "@/stores/sourceEdit";
import { useSourceDebugStore } from "@/stores/sourceDebug";
import { sourceApi } from "@/api/source";
import { SOURCE_TYPES } from "@/utils/sourceList";
import { smartBack } from "@/utils/nav";

const store = useSourceEditStore();
const debug = useSourceDebugStore();
const route = useRoute();
const router = useRouter();

const toolTab = ref<"json" | "debug" | "help">("json");
const jsonDraft = ref("");
const jsonError = ref("");

const isNew = computed(() => store.id === 0);
const title = computed(() => store.name || (isNew.value ? "新建书源" : "编辑书源"));

function syncJSONDraft(): void {
  jsonDraft.value = store.rawText;
  jsonError.value = "";
  // 输入框已经换回草稿原文，之前那段非法文本的报错不该继续拦着保存。
  store.discardRawError();
}

/** 按路由里的 id 载入草稿；从 A 源的编辑页直接跳到 B 源也走这条路。 */
async function loadFromRoute(): Promise<void> {
  const id = Number(route.params.id ?? 0);
  if (id > 0) {
    try {
      await store.open(id);
    } catch (e) {
      ElMessage.error((e as Error).message);
    }
  } else {
    store.openNew();
  }
  syncJSONDraft();
  debug.clear();
}

onMounted(async () => {
  debug.attach();
  // 从书源列表点「调试」进来时直接落到调试标签。
  if (route.query.tab === "debug") toolTab.value = "debug";
  await loadFromRoute();
  window.addEventListener("keydown", onKeydown);
});

// 同一路由只换参数时组件会被复用（onMounted 不再触发），不监听就会一直显示
// 上一个书源的草稿——列表/详情页连着点两个「编辑」是很容易踩到的路径。
watch(
  () => route.params.id,
  () => {
    loadFromRoute();
  },
);

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
});

/** Ctrl/Cmd + S 保存：编辑器里这是最强的手癖。 */
function onKeydown(e: KeyboardEvent): void {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
    e.preventDefault();
    save();
  }
}

onBeforeRouteLeave(async () => {
  if (!store.dirty) return true;
  try {
    await ElMessageBox.confirm("有未保存的修改，确定离开？", "离开书源编辑", {
      confirmButtonText: "放弃修改",
      cancelButtonText: "继续编辑",
      type: "warning",
    });
    return true;
  } catch {
    return false;
  }
});

async function save(): Promise<void> {
  try {
    const view = await store.save();
    ElMessage.success(`已保存《${view.name}》`);
    if (isNew.value) {
      // 新建成功后换成带 ID 的地址：否则再点一次保存会又插一条。
      await router.replace(`/sources/${view.id}/edit`);
    }
    jsonDraft.value = store.rawText;
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

function back(): void {
  // 用 push 会在历史里多压一条 /sources，之后连按返回要退两次才回得去。
  // 没有站内 back 入口（深链/刷新）时兜底 replace 回书源页。
  smartBack(router, "/sources", { mustMatch: "/sources" });
}

function undo(): void {
  store.undo();
  syncJSONDraft();
}

function redo(): void {
  store.redo();
  syncJSONDraft();
}

function clearForm(): void {
  ElMessageBox.confirm("清空当前表单内容？此操作可用「撤销」找回。", "清空表单", {
    confirmButtonText: "清空",
    cancelButtonText: "取消",
    type: "warning",
  })
    .then(() => {
      store.openNew();
      syncJSONDraft();
    })
    .catch(() => {});
}

/** JSON 视图：输入即解析，语法错误只提示不回滚，避免打断粘贴。 */
function onJSONInput(text: string): void {
  jsonDraft.value = text;
  const ok = store.applyRawText(text);
  jsonError.value = ok ? "" : store.rawError;
}

function formatJSON(): void {
  if (jsonError.value) {
    ElMessage.error("先修好 JSON 语法错误再格式化");
    return;
  }
  jsonDraft.value = store.serialize();
}

/** 切到调试页时把焦点给入口，顺手提醒需要一个地址。 */
function openDebugTab(): void {
  toolTab.value = "debug";
}

// ── 顶部选项行（对应原生编辑页的水平选项条）────────────────
// 原生把「类型 / 启用 / 发现 / 自动保存 Cookie」从字段表单里拎出来放顶栏，
// 因为这四个是「整源级别」的开关，跟具体规则不在一层；塞进表单里
// 用户要翻到「基础」页才找得到。
const sourceType = computed<number>({
  get: () => Number(store.getField(["bookSourceType"]) ?? 0) || 0,
  set: (v) => store.setField(["bookSourceType"], v),
});

const enabled = computed<boolean>({
  get: () => store.getField(["enabled"]) !== false,
  set: (v) => store.setField(["enabled"], v),
});

const exploreOn = computed<boolean>({
  get: () => store.getField(["enabledExplore"]) !== false,
  set: (v) => store.setField(["enabledExplore"], v),
});

const cookieJar = computed<boolean>({
  get: () => store.getField(["enabledCookieJar"]) !== false,
  set: (v) => store.setField(["enabledCookieJar"], v),
});

/** 配了发现地址才允许打开「发现」开关，否则开了也没有入口。 */
const hasExploreUrl = computed(
  () => String(store.getField(["exploreUrl"]) ?? "").trim() !== "",
);
const hasLoginUrl = computed(
  () => String(store.getField(["loginUrl"]) ?? "").trim() !== "",
);

// ── 更多菜单（登录 / 搜索 / 清 Cookie / 复制粘贴 / 源变量 / 分享）──
const loginDialog = ref(false);

/**
 * 保证书源已落库再执行动作。
 *
 * 登录、搜索、源变量、清 Cookie 都是**按已保存的书源**工作的（登录态与变量
 * 都按 bookSourceUrl 存），草稿状态下直接执行会打到一个不存在的源上。
 * 原生也是先 save 再动作。
 */
async function ensureSaved(): Promise<boolean> {
  if (store.id > 0 && !store.dirty) return true;
  try {
    await save();
    return store.id > 0;
  } catch {
    return false;
  }
}

async function onMoreCommand(cmd: string) {
  switch (cmd) {
    case "login":
      if (await ensureSaved()) loginDialog.value = true;
      break;
    case "search": {
      if (!(await ensureSaved())) return;
      void router.push({
        path: "/search",
        query: { sourceId: String(store.id), sourceName: store.name },
      });
      break;
    }
    case "clear-cookie":
      await clearCookie();
      break;
    case "copy":
      await copySource();
      break;
    case "paste":
      await pasteSource();
      break;
    case "variable":
      await editVariable();
      break;
    case "share":
      await shareSource();
      break;
  }
}

async function clearCookie() {
  if (!(await ensureSaved())) return;
  try {
    await ElMessageBox.confirm(
      `清除「${store.name}」站点保存的 Cookie？清完后需要重新登录。`,
      "清除 Cookie",
      { confirmButtonText: "清除", cancelButtonText: "取消", type: "warning" },
    );
  } catch {
    return;
  }
  try {
    await sourceApi.clearCookie(store.id);
    ElMessage.success("已清除 Cookie");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

async function copySource() {
  try {
    await navigator.clipboard.writeText(store.serialize());
    ElMessage.success("已复制书源 JSON 到剪贴板");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/**
 * 粘贴书源：整份 JSON 覆盖当前表单。
 *
 * 与原生一致，粘贴不是「合并」而是「替换」——用户的用法是「从别处拿一份
 * 书源，在这里改改再存」，合并反而会让旧字段残留。
 */
async function pasteSource() {
  let text = "";
  try {
    text = await navigator.clipboard.readText();
  } catch {
    ElMessage.error("无法读取剪贴板，请检查系统权限");
    return;
  }
  if (!text.trim()) {
    ElMessage.warning("剪贴板是空的");
    return;
  }
  try {
    const ok = store.applyRawText(text);
    if (!ok) throw new Error(store.rawError);
    syncJSONDraft();
    ElMessage.success("已粘贴书源");
  } catch (e) {
    ElMessage.error(`粘贴失败：${(e as Error).message}`);
  }
}

async function shareSource() {
  // 桌面端没有系统分享面板，落到「复制 JSON」这个最接近的动作上。
  await copySource();
}

/** 源变量：书源 JS 里通过 source.getVariable() 读取的一段文本。 */
async function editVariable() {
  if (!(await ensureSaved())) return;
  try {
    const view = await sourceApi.getVariable(store.id);
    const { value } = await ElMessageBox.prompt(
      view.comment?.trim() ||
        "书源变量，可在书源 JS 里通过 source.getVariable() 读取（留空表示清除）。",
      "设置源变量",
      {
        confirmButtonText: "保存",
        cancelButtonText: "取消",
        inputValue: view.variable || "",
        inputType: "textarea",
      },
    );
    await sourceApi.setVariable(store.id, (value || "").trim());
    ElMessage.success("已保存源变量");
  } catch (e) {
    if (e !== "cancel" && e !== "close") ElMessage.error((e as Error).message);
  }
}
</script>

<template>
  <div class="source-edit">
    <header class="bar">
      <el-button link @click="back">← 返回</el-button>
      <div class="title-wrap">
        <span class="title">{{ title }}</span>
        <span v-if="store.dirty" class="dirty" title="有未保存的修改">●</span>
      </div>
      <code v-if="store.url" class="url">{{ store.url }}</code>
      <div class="spacer" />
      <el-button size="small" :disabled="!store.canUndo" @click="undo">撤销</el-button>
      <el-button size="small" :disabled="!store.canRedo" @click="redo">重做</el-button>
      <el-dropdown trigger="click" @command="onMoreCommand">
        <el-button size="small" data-role="edit-more">更多</el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item v-if="hasLoginUrl" command="login">登录</el-dropdown-item>
            <el-dropdown-item command="search">搜索本书源</el-dropdown-item>
            <el-dropdown-item command="clear-cookie">清除 Cookie</el-dropdown-item>
            <el-dropdown-item command="variable" divided>设置源变量…</el-dropdown-item>
            <el-dropdown-item command="copy" divided>复制书源 JSON</el-dropdown-item>
            <el-dropdown-item command="paste">粘贴书源 JSON</el-dropdown-item>
            <el-dropdown-item command="share">分享（复制 JSON）</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
      <el-button size="small" type="primary" :loading="store.saving" @click="save"
        >保存</el-button
      >
    </header>

    <!-- 整源级开关：类型 / 启用 / 发现 / 自动保存 Cookie（原生放在标题栏下方） -->
    <div class="options-bar">
      <span class="opt-label">类型</span>
      <el-select v-model="sourceType" size="small" class="opt-type" data-role="source-type">
        <el-option
          v-for="(t, i) in SOURCE_TYPES"
          :key="t"
          :label="t"
          :value="i"
        />
      </el-select>
      <el-checkbox v-model="enabled" data-role="opt-enabled">启用</el-checkbox>
      <el-checkbox
        v-model="exploreOn"
        :disabled="!hasExploreUrl"
        :title="hasExploreUrl ? '' : '未配置 exploreUrl，开启也没有入口'"
        data-role="opt-explore"
        >发现</el-checkbox
      >
      <el-checkbox v-model="cookieJar" data-role="opt-cookie">
        自动保存 Cookie
      </el-checkbox>
      <span v-if="!hasExploreUrl" class="opt-hint">（该源没有发现地址）</span>
    </div>

    <div class="body" v-loading="store.loading">
      <section class="left">
        <SourceFormTabs />
      </section>

      <aside class="mid">
        <el-button size="small" type="primary" plain @click="save">✓ 保存</el-button>
        <el-button size="small" @click="openDebugTab">⇏ 调试</el-button>
        <el-button size="small" :disabled="!store.canUndo" @click="undo">↶ 撤销</el-button>
        <el-button size="small" :disabled="!store.canRedo" @click="redo">↷ 重做</el-button>
        <el-button size="small" @click="clearForm">✗ 清空</el-button>
      </aside>

      <aside class="right">
        <el-tabs v-model="toolTab" class="tool-tabs">
          <el-tab-pane name="json">
            <template #label>
              <span>JSON</span>
              <i v-if="jsonError" class="tab-dot" />
            </template>
            <div class="json-pane">
              <div class="json-actions">
                <el-button size="small" @click="formatJSON">格式化</el-button>
                <el-button size="small" @click="syncJSONDraft">重新载入</el-button>
              </div>
              <div v-if="jsonError" class="json-error">{{ jsonError }}</div>
              <el-input
                :model-value="jsonDraft"
                type="textarea"
                class="json-editor"
                spellcheck="false"
                @update:model-value="onJSONInput"
              />
            </div>
          </el-tab-pane>

          <el-tab-pane label="调试" name="debug">
            <SourceDebugPanel />
          </el-tab-pane>

          <el-tab-pane label="帮助" name="help">
            <div class="help">
              <h4>规则语法</h4>
              <ul>
                <li><code>a@b@c</code> 依次取：先用 a 定位节点，再从结果里取 b，再取 c</li>
                <li><code>规则1||规则2</code> 先试左边，取不到再用右边</li>
                <li><code>规则1&amp;&amp;规则2</code> 两个结果拼接</li>
                <li><code>@css:</code> / <code>@json:</code> / <code>@xpath:</code> 指定解析器，默认按内容猜</li>
                <li><code>@js:代码</code> 用 JS 处理上一步结果，<code>result</code> 是输入</li>
                <li><code v-pre>{{key}}</code> 取搜索页 <code>@put</code> 存下的变量</li>
                <li><code>##正则##替换</code> 对结果做替换；<code>##正则</code> 只保留匹配部分</li>
              </ul>
              <h4>调试入口</h4>
              <ul>
                <li>填书名 → 搜索，再顺链路往下跑</li>
                <li>填书籍地址 → 从详情页开始</li>
                <li>填 <code>分类::</code> → 发现页（地址留空则按分类名查）</li>
                <li>填 <code>++目录地址</code> → 从目录页开始</li>
                <li>填 <code>--正文地址</code> → 从正文页开始</li>
              </ul>
              <h4>排查顺序</h4>
              <ol>
                <li>先看「搜索」组：<code>bookList</code> 能否取到节点，<code>name</code>/<code>bookUrl</code> 是否为空</li>
                <li>再看「详情」组：<code>tocUrl</code> 是否取到；取不到说明选择器写错</li>
                <li>「目录」组常见问题：<code>chapterUrl</code> 少了 <code>@href</code>，或分卷标题被当成章节</li>
                <li>「正文」组为空时，多半是 <code>content</code> 规则命中了付费提示或提示框</li>
              </ol>
              <p class="tip">
                调试跑的是<strong>当前草稿</strong>，不用先保存；保存后书源才会进入书架搜索。
              </p>
            </div>
          </el-tab-pane>
        </el-tabs>
      </aside>
    </div>

    <SourceLoginDialog
      v-model="loginDialog"
      :source-id="store.id"
      :source-name="store.name"
      @changed="() => {}"
    />
  </div>
</template>

<style scoped>
.source-edit {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  min-width: 0;
  padding: 0 var(--r-pad) var(--r-pad-sm);
}
.bar {
  flex: none;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) 0;
  min-width: 0;
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.title-wrap {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  min-width: 0;
}
.title {
  font-size: 15px;
  font-weight: 600;
}
.dirty {
  color: var(--el-color-warning);
  font-size: 12px;
}
.url {
  font-size: 12px;
  color: var(--el-text-color-secondary);
  background: var(--el-fill-color-light);
  padding: 1px 6px;
  border-radius: 3px;
  min-width: 0;
  max-width: min(100%, 320px);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spacer {
  flex: 1;
  min-width: 0;
}
/* 整源级开关行：与标题栏同一背景，视觉上属于「页头」而不是表单 */
.options-bar {
  flex: none;
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) 0;
  min-width: 0;
  border-bottom: 1px solid var(--el-border-color-lighter);
  flex-wrap: wrap;
}
.opt-label {
  font-size: 13px;
  color: var(--el-text-color-regular);
}
.opt-type {
  width: min(100%, 96px);
  min-width: 0;
}
.opt-hint {
  font-size: 12px;
  color: var(--el-text-color-secondary);
}
.options-bar :deep(.el-checkbox) {
  margin-right: 0;
}
.body {
  flex: 1;
  min-height: 0;
  min-width: 0;
  display: flex;
  gap: var(--r-gap);
  padding-top: var(--r-pad-sm);
}
.left {
  flex: 1;
  min-width: 0;
  min-height: 0;
}
.mid {
  flex: none;
  width: min(100%, 92px);
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: var(--r-gap-sm);
  padding-top: 2px;
}
.mid .el-button {
  margin-left: 0;
  width: 100%;
  justify-content: center;
}
.right {
  flex: none;
  width: min(100%, 440px);
  min-width: 0;
  min-height: 0;
  display: flex;
  flex-direction: column;
  border-left: 1px solid var(--el-border-color-lighter);
  padding-left: var(--r-pad-sm);
}
.tool-tabs {
  height: 100%;
  display: flex;
  flex-direction: column;
  min-height: 0;
  min-width: 0;
}
.tool-tabs :deep(.el-tabs__header) {
  margin: 0 0 8px;
}
.tool-tabs :deep(.el-tabs__content) {
  flex: 1;
  min-height: 0;
  min-width: 0;
}
.tool-tabs :deep(.el-tab-pane) {
  height: 100%;
}
.tab-dot {
  display: inline-block;
  width: 6px;
  height: 6px;
  border-radius: 50%;
  background: var(--el-color-danger);
  margin-left: 4px;
  vertical-align: middle;
}
.json-pane {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  min-width: 0;
}
.json-actions {
  flex: none;
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  margin-bottom: 6px;
  min-width: 0;
}
.json-error {
  flex: none;
  font-size: 12px;
  color: var(--el-color-danger);
  margin-bottom: 6px;
  word-break: break-all;
  min-width: 0;
}
.json-editor {
  flex: 1;
  min-height: 0;
  min-width: 0;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
}
.json-editor :deep(textarea) {
  height: 100% !important;
  font-family: inherit;
  font-size: 12px;
  line-height: 1.5;
}
.help {
  height: 100%;
  overflow-y: auto;
  min-width: 0;
  font-size: 13px;
  line-height: 1.7;
  color: var(--el-text-color-regular);
}
.help h4 {
  margin: 12px 0 4px;
  font-size: 13px;
  color: var(--el-text-color-primary);
}
.help ul,
.help ol {
  margin: 0;
  padding-left: 18px;
}
.help code {
  background: var(--el-fill-color-light);
  padding: 0 3px;
  border-radius: 3px;
  font-size: 12px;
}
.help .tip {
  margin-top: 12px;
  color: var(--el-text-color-secondary);
  font-size: 12px;
}

/* 窄屏（含平板/分屏）：三栏编辑器改为单栏纵向排布，不增删任何 DOM。
   表单 / 按钮行 / 工具页依次向下堆叠，整列可纵向滚动，工具页保留可视高度。 */
@media (max-width: 1024px) {
  .source-edit {
    padding: 0 var(--r-pad-sm) var(--r-pad-sm);
  }
  .body {
    flex-direction: column;
    gap: var(--r-gap-sm);
    overflow-y: auto;
  }
  .left {
    flex: none;
    width: 100%;
    min-width: 0;
    min-height: 0;
    height: min(70vh, 600px);
    overflow-y: auto;
  }
  .mid {
    width: 100%;
    flex-direction: row;
    flex-wrap: wrap;
    padding-top: 0;
  }
  .mid .el-button {
    width: auto;
  }
  .right {
    width: 100%;
    flex: none;
    height: min(70vh, 520px);
    border-left: none;
    border-top: 1px solid var(--el-border-color-lighter);
    padding-left: 0;
    padding-top: var(--r-pad-sm);
  }
}
</style>
