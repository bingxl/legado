<script setup lang="ts">
/**
 * 本章进度条（阅读器底部）。
 *
 * 只做两件事：显示百分比、把指针位置换算成百分比后抛给父组件。
 * 真正的「滚到哪里」由阅读器决定——文本、漫画是不同容器，PDF 根本滚不了，
 * 这些差异不该漏到这里来。
 *
 * 拖动的关键是**不靠 props.percent 驱动滑块**：父组件把百分比换算成 scrollTop
 * 时会被内容高度夹住（章节不足一屏、漫画图片还在懒加载），回流值低于手指位置，
 * 滑块就会在手指底下往回跳。所以拖动期间滑块跟本地 dragPct 走。
 */
import { computed, ref } from "vue";

import { clampPercent, percentFromX } from "@/utils/chapterProgress";

const props = withDefaults(
  defineProps<{
    /** 当前进度 0~100，由正文滚动位置得出。 */
    percent: number;
    /** 不可交互：PDF（滚动归 iframe 管）、文件缺失、章节不足一屏。 */
    disabled?: boolean;
  }>(),
  { disabled: false },
);

const emit = defineEmits<{
  /** 指针按下/移动：父组件据此滚动正文。 */
  (e: "seek", percent: number): void;
  /** 抬手：父组件此时才落盘进度（拖动中每一像素都写库没有意义）。 */
  (e: "seek-end", percent: number): void;
}>();

const trackRef = ref<HTMLElement | null>(null);
const dragging = ref(false);
/** 拖动期间的本地百分比：跟手，不受父组件回流值影响。 */
const dragPct = ref(0);

const shown = computed(() => {
  const v = dragging.value ? dragPct.value : props.percent;
  return clampPercent(v);
});

function pctAt(clientX: number): number {
  const r = trackRef.value?.getBoundingClientRect();
  if (!r) return 0;
  return percentFromX(clientX, r.left, r.width);
}

function onPointerDown(e: PointerEvent) {
  if (props.disabled) return;
  // 默认行为会让桌面端拖出选区、移动端交给页面滚动，两者都会把拖动打断。
  e.preventDefault();
  dragging.value = true;
  dragPct.value = pctAt(e.clientX);
  const el = e.currentTarget as HTMLElement;
  // 捕获指针：手指/鼠标移出轨道甚至移出窗口也继续跟着走，直到抬手。
  try {
    el.setPointerCapture(e.pointerId);
  } catch {
    // 少数环境不支持指针捕获，退化成「只在轨道内跟随」，不影响点击跳转。
  }
  emit("seek", dragPct.value);
}

function onPointerMove(e: PointerEvent) {
  if (!dragging.value) return;
  dragPct.value = pctAt(e.clientX);
  emit("seek", dragPct.value);
}

function onPointerUp(e: PointerEvent) {
  if (!dragging.value) return;
  dragging.value = false;
  const el = e.currentTarget as HTMLElement;
  try {
    if (el.hasPointerCapture?.(e.pointerId)) el.releasePointerCapture(e.pointerId);
  } catch {
    // 同上，没有捕获就没有可释放的。
  }
  emit("seek-end", dragPct.value);
}
</script>

<template>
  <div
    class="chapter-progress"
    :class="{ 'is-disabled': disabled, 'is-dragging': dragging }"
  >
    <span class="cp-label">本章</span>
    <div
      ref="trackRef"
      class="cp-track"
      data-progress="chapter"
      role="slider"
      aria-label="本章进度"
      aria-valuemin="0"
      aria-valuemax="100"
      :aria-valuenow="Math.round(shown)"
      :aria-disabled="disabled"
      @pointerdown="onPointerDown"
      @pointermove="onPointerMove"
      @pointerup="onPointerUp"
      @pointercancel="onPointerUp"
    >
      <div class="cp-fill" :style="{ width: shown + '%' }" />
      <span class="cp-thumb" :style="{ left: shown + '%' }" />
    </div>
    <span class="cp-pct" data-progress="pct">{{ Math.round(shown) }}%</span>
  </div>
</template>

<style scoped>
.chapter-progress {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  flex: none;
  min-width: 0;
  /* 只有 4px 的线，行高必须压到最小：这一行是实打实从正文可视高度里扣出来的 */
  padding: 3px var(--r-pad) 4px;
  background: #fff;
  user-select: none;
  -webkit-user-select: none;
}
.cp-label,
.cp-pct {
  flex: none;
  font-size: 12px;
  line-height: 14px;
  color: #6b7280;
  font-variant-numeric: tabular-nums;
}
/* 轨道只有 4px 高：上下各外扩 6px 造命中区，手指不必对准细线 */
.cp-track {
  position: relative;
  flex: 1;
  min-width: 0;
  height: 4px;
  border-radius: 2px;
  background: #e5e7eb;
  cursor: pointer;
  /* 触屏上拖动进度条不能被识别成页面滚动，否则滑一下就变成滚正文 */
  touch-action: none;
}
.cp-track::before {
  content: "";
  position: absolute;
  left: 0;
  right: 0;
  top: -7px;
  bottom: -7px;
}
.cp-fill {
  position: absolute;
  left: 0;
  top: 0;
  bottom: 0;
  border-radius: 2px;
  background: #4f46e5;
}
.cp-thumb {
  position: absolute;
  top: 50%;
  width: 11px;
  height: 11px;
  margin-left: -5.5px;
  box-sizing: border-box;
  border: 2px solid #4f46e5;
  border-radius: 50%;
  background: #fff;
  transform: translateY(-50%);
  /* 常态隐藏：阅读时一根细线就够了，悬停/拖动才浮出手柄提示可拖 */
  opacity: 0;
  transition: opacity 0.15s ease;
}
.chapter-progress:hover .cp-thumb,
.chapter-progress.is-dragging .cp-thumb {
  opacity: 1;
}
.is-disabled .cp-track {
  cursor: default;
}
/* 置灰而不是清空：不足一屏时进度确实是 100%，只是没得拖 */
.is-disabled .cp-fill {
  opacity: 0.45;
}
.is-disabled .cp-thumb {
  display: none;
}
@media (max-width: 640px) {
  .chapter-progress {
    gap: 6px;
    padding: 2px var(--r-pad-sm) 3px;
  }
  .cp-label {
    font-size: 11px;
    line-height: 13px;
  }
  .cp-pct {
    font-size: 11px;
    line-height: 13px;
  }
}
</style>
