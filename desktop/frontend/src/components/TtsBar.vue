<script setup lang="ts">
/**
 * 朗读播放条（常驻在应用外壳底部）。
 *
 * 挂在 App 而不是阅读器里，是为了「离开阅读器继续朗读」：
 * 段落和播放器都在 store 里，路由切换不影响。
 */
import { computed } from "vue";
import { useRouter } from "vue-router";

import { useTtsStore } from "@/stores/tts";
import { langLabel } from "@/tts/voice";

const tts = useTtsStore();
const router = useRouter();

const RATES = [75, 100, 125, 150, 200];

const playLabel = computed(() => {
  if (tts.status === "preparing") return "…";
  if (tts.status === "playing") return "暂停";
  return "继续";
});

const progress = computed(() => {
  if (!tts.segCount) return 0;
  return Math.round(((tts.segIndex + 1) / tts.segCount) * 100);
});

/** 有声书常见需求：边听边看，点一下回到正在读的位置。 */
function backToBook() {
  if (!tts.bookId) return;
  void router.push(`/reader/${tts.bookId}`);
}
</script>

<template>
  <div class="tts-bar" :class="'is-' + tts.status">
    <div class="tts-progress"><i :style="{ width: progress + '%' }" /></div>

    <button class="tts-book" :title="'回到阅读：' + tts.bookName" @click="backToBook">
      {{ tts.bookName || "朗读" }}
    </button>
    <span class="tts-chapter">{{ tts.chapterTitle }}</span>
    <span class="tts-count">{{ tts.segIndex + 1 }} / {{ tts.segCount }}</span>

    <span v-if="tts.status === 'error'" class="tts-error">{{ tts.errorMsg }}</span>

    <div class="spacer" />

    <button class="tts-btn tts-prev" title="上一段" @click="tts.step(-1)">⏮</button>
    <button
      class="tts-btn tts-play"
      :disabled="tts.status === 'preparing'"
      :title="playLabel"
      @click="tts.toggle()"
    >
      {{ playLabel }}
    </button>
    <button class="tts-btn tts-next" title="下一段" @click="tts.step(1)">⏭</button>

    <el-select
      class="tts-rate"
      :model-value="tts.rate"
      size="small"
      style="width: 86px"
      @update:model-value="(v: number) => tts.setRate(v)"
    >
      <el-option v-for="r in RATES" :key="r" :label="r / 100 + '×'" :value="r" />
    </el-select>

    <el-select
      class="tts-voice"
      :model-value="tts.voiceId"
      size="small"
      placeholder="默认音色"
      style="width: 190px"
      @update:model-value="(v: string) => tts.setVoice(v)"
    >
      <el-option
        v-for="v in tts.voices"
        :key="v.id"
        :label="v.name + ' · ' + langLabel(v.lang)"
        :value="v.id"
      />
    </el-select>

    <button class="tts-btn tts-stop" title="停止朗读" @click="tts.stop()">✕</button>
  </div>
</template>

<style scoped>
.tts-bar {
  position: relative;
  display: flex;
  align-items: center;
  gap: 10px;
  flex: none;
  height: 52px;
  padding: 0 14px;
  background: #fff;
  border-top: 1px solid #e5e7eb;
  box-shadow: 0 -2px 10px rgba(15, 23, 42, 0.04);
}
.tts-progress {
  position: absolute;
  top: -1px;
  left: 0;
  right: 0;
  height: 2px;
  background: #eef2ff;
}
.tts-progress i {
  display: block;
  height: 100%;
  background: #4338ca;
  transition: width 0.25s linear;
}
.tts-book {
  max-width: 180px;
  padding: 0;
  border: none;
  background: none;
  font-size: 13px;
  font-weight: 600;
  color: #111827;
  cursor: pointer;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tts-book:hover {
  color: #4338ca;
}
.tts-chapter {
  max-width: 220px;
  font-size: 12px;
  color: #6b7280;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.tts-count {
  font-size: 12px;
  color: #9ca3af;
  font-variant-numeric: tabular-nums;
}
.tts-error {
  font-size: 12px;
  color: #b91c1c;
  max-width: 320px;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spacer {
  flex: 1;
}
.tts-btn {
  min-width: 34px;
  height: 30px;
  padding: 0 10px;
  border: 1px solid #e5e7eb;
  border-radius: 8px;
  background: #fff;
  font-size: 13px;
  color: #374151;
  cursor: pointer;
}
.tts-btn:hover:not(:disabled) {
  background: #f3f4f6;
}
.tts-btn:disabled {
  cursor: default;
  opacity: 0.5;
}
.tts-play {
  min-width: 58px;
  font-weight: 600;
  color: #4338ca;
  border-color: #c7d2fe;
  background: #eef2ff;
}
.tts-play:hover:not(:disabled) {
  background: #e0e7ff;
}
.tts-stop {
  color: #9ca3af;
}
.is-error .tts-count {
  display: none;
}
</style>
