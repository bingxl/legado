<script setup lang="ts">
/**
 * 书源调试面板。
 *
 * 交互对照 Legado 客户端的「调试源」：给一个入口，后端按 搜索/发现 → 详情 →
 * 目录 → 正文 的顺序真跑一遍规则，把每一步的请求与求值结果按行打出来。
 *
 * 与客户端不同的是这里能直接调试**未保存的草稿**（后端接受 raw），
 * 所以改完规则不用先保存——这本来就是调试最该有的样子。
 */
import { computed, nextTick, ref, watch } from "vue";
import { ElMessage } from "element-plus";

import { DebugEntryKind, useSourceDebugStore } from "@/stores/sourceDebug";
import { DebugStage, type DebugStageValue } from "@/api/sourcedebug";
import { useSourceEditStore } from "@/stores/sourceEdit";

const store = useSourceDebugStore();
const edit = useSourceEditStore();

const entry = ref("");
const stage = ref<DebugStageValue>(DebugStage.Content);
const outputEl = ref<HTMLElement | null>(null);
const entryKind = ref<(typeof DebugEntryKind)[keyof typeof DebugEntryKind]>(DebugEntryKind.Search);

const stageOptions: { value: DebugStageValue; label: string }[] = [
  { value: DebugStage.Content, label: "跑到正文（完整链路）" },
  { value: DebugStage.Toc, label: "跑到目录" },
  { value: DebugStage.Info, label: "跑到详情" },
  { value: DebugStage.Search, label: "只跑搜索" },
  { value: DebugStage.Explore, label: "只跑发现" },
];

/** 入口形态说明：点一下把对应前缀填进输入框，省得记语法。 */
const entryHints = [
  { kind: DebugEntryKind.Search, label: "关键词", sample: "剑来", tip: "搜索「剑来」，再顺着详情→目录→正文往下跑" },
  { kind: DebugEntryKind.Detail, label: "书籍地址", sample: "https://site.com/book/1", tip: "从详情页开始" },
  { kind: DebugEntryKind.Explore, label: "分类::地址", sample: "玄幻::", tip: "发现页；地址留空则按分类名查书源里的发现地址" },
  { kind: DebugEntryKind.Toc, label: "++目录地址", sample: "++https://site.com/toc", tip: "从目录页开始" },
  { kind: DebugEntryKind.Content, label: "--正文地址", sample: "--https://site.com/chapter/1", tip: "从正文页开始" },
] as const;

const canRun = computed(() => entry.value.trim() !== "" && !store.running);

function pickHint(sample: string, kind: (typeof DebugEntryKind)[keyof typeof DebugEntryKind]): void {
  entryKind.value = kind;
  entry.value = sample;
}

async function run(): Promise<void> {
  if (!canRun.value) return;
  if (!edit.url) {
    ElMessage.warning("请先在「基础」里填写源域名（bookSourceUrl），调试需要它确定变量作用域");
    return;
  }
  try {
    await store.start(edit.id, edit.draftRaw(), entry.value.trim(), stage.value);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

function stop(): void {
  store.stop();
}

function clear(): void {
  store.clear();
}

/** 复制全部输出，便于贴到 issue 里。 */
async function copyAll(): Promise<void> {
  const text = store.lines
    .map((l) => `[${store.formatElapsed(l.elapsedMs)}] ${l.msg}`)
    .join("\n");
  try {
    await navigator.clipboard.writeText(text);
    ElMessage.success("已复制调试输出");
  } catch {
    ElMessage.error("复制失败");
  }
}

// 新行到达时贴底（用户手动上滚后就不要抢滚动条了，这里用 autoScroll 开关控制）。
watch(
  () => store.lines.length,
  async () => {
    if (!store.autoScroll) return;
    await nextTick();
    const el = outputEl.value;
    if (el) el.scrollTop = el.scrollHeight;
  },
);
</script>

<template>
  <div class="debug-panel">
    <div class="entry">
      <el-input
        v-model="entry"
        placeholder="书名 / 书籍地址 / 分类::地址 / ++目录 / --正文"
        clearable
        @keydown.enter="run"
      >
        <template #append>
          <el-select v-model="stage" style="width: 156px">
            <el-option
              v-for="o in stageOptions"
              :key="o.value"
              :label="o.label"
              :value="o.value"
            />
          </el-select>
        </template>
      </el-input>
      <div class="entry-actions">
        <el-button
          v-if="!store.running"
          type="primary"
          size="small"
          :disabled="!canRun"
          @click="run"
          >开始调试</el-button
        >
        <el-button v-else type="danger" size="small" @click="stop">停止</el-button>
        <el-button size="small" :disabled="!store.hasOutput" @click="clear"
          >清空</el-button
        >
        <el-button size="small" :disabled="!store.hasOutput" @click="copyAll"
          >复制</el-button
        >
        <el-checkbox v-model="store.autoScroll" size="small" class="auto-scroll"
          >自动滚动</el-checkbox
        >
      </div>
      <div class="hints">
        <span class="hints-title">入口：</span>
        <el-tag
          v-for="h in entryHints"
          :key="h.kind"
          size="small"
          :type="entryKind === h.kind ? 'primary' : 'info'"
          effect="plain"
          class="hint-tag"
          :title="h.tip"
          @click="pickHint(h.sample, h.kind)"
          >{{ h.label }}</el-tag
        >
      </div>
    </div>

    <div class="status" :class="{ bad: store.failed, good: store.finished && !store.failed }">
      <span>{{ store.statusText }}</span>
      <span v-if="store.finished" class="elapsed">
        {{ (store.elapsedMs / 1000).toFixed(1) }}s
      </span>
    </div>

    <div ref="outputEl" class="output">
      <div v-if="!store.hasOutput" class="output-empty">
        还没有输出。填一个入口后点「开始调试」。<br />
        调试会真发请求，命中不了的规则会在这一行标红。
      </div>
      <div
        v-for="line in store.lines"
        :key="line.id"
        :class="['line', line.kind]"
      >
        <span class="ts">[{{ store.formatElapsed(line.elapsedMs) }}]</span>
        <span
          v-if="line.collapsible"
          class="body-badge"
          @click="store.toggleLine(line.id)"
          :title="line.expanded ? '收起响应体' : '展开响应体'"
          >{{ line.expanded ? "▾" : "▸" }} 响应体</span
        >
        <pre v-if="!line.collapsible || line.expanded" class="msg">{{ line.msg }}</pre>
        <span v-else class="msg collapsed">{{ line.msg.slice(0, 120) }}</span>
      </div>
    </div>
  </div>
</template>

<style scoped>
.debug-panel {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
}
.entry {
  flex: none;
}
.entry-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 6px;
}
.auto-scroll {
  margin-left: auto;
  font-size: 12px;
}
.hints {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 4px;
  margin-top: 6px;
}
.hints-title {
  font-size: 12px;
  color: var(--el-text-color-secondary);
}
.hint-tag {
  cursor: pointer;
}
.status {
  flex: none;
  margin: 8px 0 4px;
  font-size: 12px;
  color: var(--el-text-color-secondary);
  display: flex;
  justify-content: space-between;
}
.status.good {
  color: var(--el-color-success);
}
.status.bad {
  color: var(--el-color-danger);
}
.output {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  background: var(--el-fill-color-lighter);
  border-radius: 6px;
  padding: 8px 10px;
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
  font-size: 12px;
  line-height: 1.55;
}
.output-empty {
  color: var(--el-text-color-placeholder);
  font-family: inherit;
  line-height: 1.8;
}
.line {
  display: flex;
  gap: 6px;
  align-items: flex-start;
  white-space: pre-wrap;
  word-break: break-all;
}
.ts {
  flex: none;
  color: var(--el-text-color-placeholder);
  user-select: none;
}
.line.error .msg {
  color: var(--el-color-danger);
}
.line.done .msg {
  color: var(--el-color-success);
  font-weight: 600;
}
.msg {
  margin: 0;
  font: inherit;
  flex: 1;
  min-width: 0;
}
.msg.collapsed {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--el-text-color-secondary);
}
.body-badge {
  flex: none;
  cursor: pointer;
  color: var(--el-color-primary);
  background: var(--el-color-primary-light-9);
  border-radius: 3px;
  padding: 0 4px;
  font-size: 11px;
}
</style>
