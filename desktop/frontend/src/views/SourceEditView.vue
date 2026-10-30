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
import { computed, onBeforeUnmount, onMounted, ref } from "vue";
import { onBeforeRouteLeave, useRoute, useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import SourceFormTabs from "@/components/source/SourceFormTabs.vue";
import SourceDebugPanel from "@/components/source/SourceDebugPanel.vue";
import { useSourceEditStore } from "@/stores/sourceEdit";
import { useSourceDebugStore } from "@/stores/sourceDebug";

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
}

onMounted(async () => {
  debug.attach();
  // 从书源列表点「调试」进来时直接落到调试标签。
  if (route.query.tab === "debug") toolTab.value = "debug";
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
  window.addEventListener("keydown", onKeydown);
});

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
  router.push("/sources");
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
      <el-button size="small" type="primary" :loading="store.saving" @click="save"
        >保存</el-button
      >
    </header>

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
  </div>
</template>

<style scoped>
.source-edit {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  padding: 0 16px 12px;
}
.bar {
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 0;
  border-bottom: 1px solid var(--el-border-color-lighter);
}
.title-wrap {
  display: flex;
  align-items: center;
  gap: 4px;
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
  max-width: 320px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spacer {
  flex: 1;
}
.body {
  flex: 1;
  min-height: 0;
  display: flex;
  gap: 12px;
  padding-top: 10px;
}
.left {
  flex: 1;
  min-width: 0;
  min-height: 0;
}
.mid {
  flex: none;
  width: 92px;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding-top: 2px;
}
.mid .el-button {
  margin-left: 0;
  width: 100%;
  justify-content: center;
}
.right {
  flex: none;
  width: 440px;
  min-height: 0;
  display: flex;
  flex-direction: column;
  border-left: 1px solid var(--el-border-color-lighter);
  padding-left: 12px;
}
.tool-tabs {
  height: 100%;
  display: flex;
  flex-direction: column;
  min-height: 0;
}
.tool-tabs :deep(.el-tabs__header) {
  margin: 0 0 8px;
}
.tool-tabs :deep(.el-tabs__content) {
  flex: 1;
  min-height: 0;
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
}
.json-actions {
  flex: none;
  display: flex;
  gap: 6px;
  margin-bottom: 6px;
}
.json-error {
  flex: none;
  font-size: 12px;
  color: var(--el-color-danger);
  margin-bottom: 6px;
  word-break: break-all;
}
.json-editor {
  flex: 1;
  min-height: 0;
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
</style>
