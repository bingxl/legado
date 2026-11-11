<script setup lang="ts">
/**
 * 取词浮层。
 *
 * 定位用 `position: fixed` + 选区 `getBoundingClientRect()`：正文容器是滚动容器，
 * 用 absolute 会让浮层随滚动跑掉。滚动时直接关闭浮层（阅读器负责），
 * 比"跟随滚动"省心且不会挡住正在读的行。
 *
 * 移动端不是把同一个浮层缩小，而是换成底部卡片：指头按在选区上时，
 * 320px 宽的浮层会正好盖住被查的那个词。
 */
import { computed, onBeforeUnmount, ref, watch } from "vue";

import type { DictResultView } from "@/api/dict";

const props = defineProps<{
  visible: boolean;
  loading: boolean;
  error: string;
  result: DictResultView | null;
  anchor: { left: number; top: number; width: number; height: number } | null;
  mobile: boolean;
}>();

const emit = defineEmits<{
  close: [];
  lookup: [word: string];
  play: [word: string];
}>();

/** 浮层宽度（桌面端）。 */
const WIDTH = 340;
/** 与视口边缘的最小间距。 */
const MARGIN = 8;
/** 估算高度，用于判断下方是否放得下。 */
const EST_HEIGHT = 300;

/**
 * 计算浮层位置。
 *
 * 三条规则：
 *  1. 默认放在选区**下方**——放在上方会盖住刚读过的上下文；
 *  2. 下方放不下就上翻，但不能进 `y < 60` 的区域（顶栏与 element-plus
 *     toast 都在那一片，被盖住时用户以为浮层没弹出来）；
 *  3. 横向不超出视口。
 */
const pos = computed(() => {
  if (props.mobile || !props.anchor) return null;
  const a = props.anchor;
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let left = a.left;
  if (left + WIDTH > vw - MARGIN) left = vw - WIDTH - MARGIN;
  left = Math.max(MARGIN, left);

  let top = a.top + a.height + 8;
  let above = false;
  if (top + EST_HEIGHT > vh - MARGIN) {
    const flipped = a.top - EST_HEIGHT - 8;
    if (flipped > 60) {
      top = flipped;
      above = true;
    } else {
      // 上下都放不下：贴底显示，靠滚动查看全部内容。
      top = Math.max(60, vh - EST_HEIGHT - MARGIN);
    }
  }
  return {
    left: `${left}px`,
    top: `${top}px`,
    width: `${WIDTH}px`,
    transformOrigin: above ? "bottom left" : "top left",
  };
});

/** 来源要显示出来：四种来源的覆盖面不同，不标用户无法判断可信度。 */
const sourceLabel = computed(() => {
  switch (props.result?.source) {
    case "core":
      return "内置核心词库";
    case "full":
      return "完整词库";
    case "cedict":
      return "汉英词典 · CC-CEDICT";
    default:
      return "";
  }
});

/** 命中方式的可信度提示。 */
const matchNote = computed(() => {
  const r = props.result;
  if (!r) return "";
  if (r.ruleGuess) return "按词形规则推测，未必准确";
  if (r.matchedBy === "prefix") return "没有完全匹配，下面是相近词";
  if (r.matchedBy === "single") return "未收录该词，按单字给出";
  return "";
});

/** 释义按行拆开：ECDICT 的 translation 用换行分条。 */
function lines(text: string): string[] {
  return text
    .split("\n")
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 词频信息拼成一行；没有就返回空串。 */
function freqText(r: DictResultView): string {
  const e = entries.value[0];
  if (!e) return "";
  const parts: string[] = [];
  if ((e.bnc ?? 0) > 0) parts.push(`BNC ${e.bnc}`);
  if ((e.frq ?? 0) > 0) parts.push(`COCA ${e.frq}`);
  if ((e.collins ?? 0) > 0) parts.push(`柯林斯 ${"★".repeat(e.collins ?? 0)}`);
  if (e.oxford) parts.push("牛津 3000");
  return parts.join(" · ");
}

/** 词条列表：绑定的 entries 允许为 null，模板里统一收敛成数组。 */
const entries = computed(() => props.result?.entries ?? []);

function entryTitle(index: number): string {
  const e = entries.value[index];
  if (!e) return "";
  return e.pinyin ? `${e.word} ${e.pinyin}` : e.word;
}

/**
 * 点浮层外部关闭。
 *
 * 不用全屏遮罩：遮罩会挡住正文，用户想「再选另一个词」时第一次点击
 * 只把浮层关掉、选不中任何东西，表现为"点一下就没反应"。
 * 用文档级 mousedown 判定更贴近直觉——点在正文上照常开始新的选择。
 */
const rootRef = ref<HTMLElement | null>(null);

function onDocMouseDown(e: MouseEvent) {
  if (!props.visible) return;
  const el = rootRef.value;
  if (el && !el.contains(e.target as Node)) emit("close");
}

watch(
  () => props.visible,
  (v) => {
    // 捕获阶段：正文的 mousedown 处理器可能 stopPropagation，
    // 冒泡阶段监听会漏掉，浮层就一直挂着。
    if (v) document.addEventListener("mousedown", onDocMouseDown, true);
    else document.removeEventListener("mousedown", onDocMouseDown, true);
  },
);

onBeforeUnmount(() =>
  document.removeEventListener("mousedown", onDocMouseDown, true),
);
</script>

<template>
  <div v-if="visible" ref="rootRef" class="dict-layer">
    <section
      class="dict-pop"
      :class="{ mobile }"
      :style="pos || undefined"
      data-dict="popover"
      @mousedown.stop
      @click.stop
    >
      <header class="dp-head">
        <div class="dp-title">
          <span class="dp-word" data-dict="word">{{ result?.query || "查词" }}</span>
          <button
            v-if="result?.query"
            class="dp-icon"
            title="朗读"
            data-dict="play"
            @click="emit('play', result!.query)"
          >
            🔊
          </button>
        </div>
        <button class="dp-icon dp-close" title="关闭" data-dict="close" @click="emit('close')">
          ✕
        </button>
      </header>

      <div v-if="loading" class="dp-loading" data-dict="loading">查询中…</div>

      <div v-else-if="error" class="dp-error" data-dict="error">{{ error }}</div>

      <template v-else-if="result">
        <p v-if="entries[0]?.phonetic" class="dp-phonetic">
          /{{ entries[0].phonetic }}/
        </p>

        <!-- 变体说明：查 perceived 得到 perceive 的释义时，不说明会以为查错了词 -->
        <p v-if="result.lemma" class="dp-form">
          {{ result.query }} 是
          <button class="dp-link" @click="emit('lookup', result!.lemma)">
            {{ result.lemma }}
          </button>
          的{{ result.formLabel || "变形" }}
        </p>

        <ul v-if="entries.length" class="dp-entries">
          <li v-for="(e, i) in entries" :key="i" class="dp-entry">
            <div v-if="entries.length > 1" class="dp-entry-word">
              {{ entryTitle(i) }}
              <span v-if="e.note" class="dp-note">{{ e.note }}</span>
            </div>
            <div class="dp-defs">
              <span v-if="e.pos" class="dp-pos">{{ e.pos }}</span>
              <span v-for="(l, j) in lines(e.translation)" :key="j" class="dp-def">{{ l }}</span>
            </div>
            <div v-if="e.tags?.length || i === 0" class="dp-meta">
              <span v-if="e.tags?.length">{{ e.tags.join(" · ") }}</span>
              <span v-if="i === 0 && freqText(result)">{{ freqText(result) }}</span>
            </div>
          </li>
        </ul>

        <p v-if="matchNote" class="dp-note-line">{{ matchNote }}</p>
        <p v-if="result.hint" class="dp-hint" data-dict="hint">{{ result.hint }}</p>

        <div v-if="result.suggestions?.length" class="dp-suggest">
          <span class="dp-suggest-label">相近词</span>
          <button
            v-for="s in result.suggestions"
            :key="s"
            class="dp-chip"
            @click="emit('lookup', s)"
          >
            {{ s }}
          </button>
        </div>

        <footer v-if="sourceLabel" class="dp-foot" data-dict="source">
          来源：{{ sourceLabel }}
        </footer>
      </template>
    </section>
  </div>
</template>

<style scoped>
.dict-layer {
  position: fixed;
  inset: 0;
  z-index: 2400;
  /* 整层不吃事件：点在正文上要能继续选词，浮层自己再恢复事件。 */
  pointer-events: none;
}
.dict-pop {
  position: fixed;
  pointer-events: auto;
  box-sizing: border-box;
  max-width: min(320px, calc(100vw - 24px));
  max-height: 60vh;
  overflow-y: auto;
  padding: 12px 14px;
  background: #fff;
  border: 1px solid #e4e7ed;
  border-radius: 10px;
  box-shadow: 0 8px 28px rgb(0 0 0 / 18%);
  font-size: 14px;
  line-height: 1.6;
  animation: dp-in 0.12s ease-out;
}
/* 移动端：底部卡片。选中区通常就在手指下面，浮层压在它上面等于看不见。 */
.dict-pop.mobile {
  left: 0;
  right: 0;
  bottom: 0;
  top: auto;
  width: auto;
  /* 底部卡片保持贴边全宽，不受桌面浮层的宽度上限约束。 */
  max-width: none;
  max-height: 55vh;
  border-radius: 14px 14px 0 0;
  padding-bottom: calc(12px + env(safe-area-inset-bottom, 0px));
  animation: dp-up 0.16s ease-out;
}
@keyframes dp-in {
  from {
    opacity: 0;
    transform: translateY(-4px);
  }
}
@keyframes dp-up {
  from {
    transform: translateY(12px);
  }
}
.dp-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.dp-title {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.dp-word {
  font-size: 17px;
  font-weight: 600;
  color: #1f2329;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dp-icon {
  border: none;
  background: transparent;
  cursor: pointer;
  font-size: 14px;
  line-height: 1;
  padding: 4px;
  border-radius: 6px;
  color: #606266;
}
.dp-icon:hover {
  background: #f2f3f5;
}
.dp-close {
  margin-left: auto;
}
.dp-phonetic {
  margin: 2px 0 6px;
  color: #909399;
  font-family: "Segoe UI", system-ui, sans-serif;
}
.dp-form {
  margin: 0 0 6px;
  color: #8a6d3b;
  background: #fdf6ec;
  border-radius: 6px;
  padding: 4px 8px;
  font-size: 13px;
}
.dp-link {
  border: none;
  background: transparent;
  padding: 0;
  color: #409eff;
  cursor: pointer;
  font-size: inherit;
}
.dp-entries {
  margin: 0;
  padding: 0;
  list-style: none;
}
.dp-entry + .dp-entry {
  margin-top: 8px;
  padding-top: 8px;
  border-top: 1px dashed #ebeef5;
}
.dp-entry-word {
  font-weight: 600;
  color: #303133;
}
.dp-note {
  font-weight: 400;
  color: #909399;
  font-size: 12px;
  margin-left: 6px;
}
.dp-defs {
  display: flex;
  flex-wrap: wrap;
  gap: 4px 8px;
  color: #303133;
}
.dp-pos {
  color: #c45656;
  font-style: italic;
}
.dp-def {
  display: block;
  width: 100%;
}
.dp-meta {
  display: flex;
  gap: 10px;
  color: #a8abb2;
  font-size: 12px;
  margin-top: 2px;
}
.dp-note-line,
.dp-hint {
  margin: 8px 0 0;
  font-size: 13px;
  color: #909399;
  background: #f7f8fa;
  border-radius: 6px;
  padding: 6px 8px;
}
.dp-suggest {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  margin-top: 8px;
}
.dp-suggest-label {
  color: #909399;
  font-size: 12px;
}
.dp-chip {
  border: 1px solid #dcdfe6;
  background: #fff;
  border-radius: 999px;
  padding: 1px 10px;
  font-size: 13px;
  color: #303133;
  cursor: pointer;
}
.dp-chip:hover {
  border-color: #409eff;
  color: #409eff;
}
.dp-foot {
  margin-top: 10px;
  padding-top: 8px;
  border-top: 1px solid #f0f1f3;
  color: #a8abb2;
  font-size: 12px;
}
.dp-loading,
.dp-error {
  padding: 10px 0;
  color: #909399;
}
.dp-error {
  color: #f56c6c;
}
</style>
