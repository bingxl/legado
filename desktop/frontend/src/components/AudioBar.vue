<script setup lang="ts">
/**
 * 听书常驻迷你播放条（挂在 App 外壳底部）。
 *
 * 与 TtsBar 同理：播放器与状态都在 store 里，离开播放页也能继续控制。
 * 点书名回到独立播放页；浅色主题，样式与 TtsBar 协调。
 */
import { computed } from "vue";
import { useRouter } from "vue-router";

import { useAudioPlayerStore } from "@/stores/audioPlayer";

const audio = useAudioPlayerStore();
const router = useRouter();

const progress = computed(() => audio.progressPct);
const playLabel = computed(() => {
  if (audio.status === "loading") return "…";
  if (audio.status === "playing") return "暂停";
  if (audio.status === "error") return "重试";
  return "继续";
});

function backToPlayer() {
  if (!audio.bookId) return;
  void router.push({ name: "audio", params: { id: String(audio.bookId) } });
}
</script>

<template>
  <div class="audio-bar" :class="'is-' + audio.status">
    <div class="audio-progress"><i :style="{ width: progress + '%' }" /></div>

    <button
      class="audio-book"
      :title="'回到播放：' + audio.bookName"
      @click="backToPlayer"
    >
      {{ audio.bookName || "听书" }}
    </button>
    <span class="audio-chapter">{{ audio.chapterTitle }}</span>

    <span v-if="audio.status === 'error'" class="audio-error">{{ audio.errorMsg }}</span>

    <div class="spacer" />

    <button class="ab-btn" title="上一章" @click="audio.prev()">⏮</button>
    <button class="ab-btn ab-play" :title="playLabel" @click="audio.toggle()">
      {{ playLabel }}
    </button>
    <button class="ab-btn" title="下一章" @click="audio.next()">⏭</button>
    <button class="ab-btn ab-stop" title="停止播放" @click="audio.stop()">✕</button>
  </div>
</template>

<style scoped>
.audio-bar {
  position: relative;
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  flex: none;
  min-height: 52px;
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: #fff;
  border-top: 1px solid #e5e7eb;
  box-shadow: 0 -2px 10px rgba(15, 23, 42, 0.04);
}
.audio-progress {
  position: absolute;
  top: -1px;
  left: 0;
  right: 0;
  min-width: 0;
  max-width: 100%;
  height: 2px;
  background: #eef2ff;
}
.audio-progress i {
  display: block;
  min-width: 0;
  max-width: 100%;
  height: 100%;
  background: #4338ca;
  transition: width 0.25s linear;
}
.audio-book {
  max-width: 180px;
  min-width: 0;
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
.audio-book:hover {
  color: #4338ca;
}
.audio-chapter {
  max-width: 220px;
  min-width: 0;
  font-size: 12px;
  color: #6b7280;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.audio-error {
  font-size: 12px;
  color: #b91c1c;
  max-width: 320px;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spacer {
  flex: 1;
  min-width: 0;
}
.ab-btn {
  min-width: 34px;
  height: 30px;
  padding: 0 var(--r-pad-sm);
  border: 1px solid #e5e7eb;
  border-radius: var(--r-radius-sm);
  background: #fff;
  font-size: 13px;
  color: #374151;
  cursor: pointer;
  white-space: nowrap;
}
.ab-btn:hover {
  background: #f3f4f6;
}
.ab-play {
  min-width: 58px;
  font-weight: 600;
  color: #4338ca;
  border-color: #c7d2fe;
  background: #eef2ff;
}
.ab-play:hover {
  background: #e0e7ff;
}
.ab-stop {
  color: #9ca3af;
}

@media (max-width: 640px) {
  .audio-bar {
    gap: var(--r-gap-sm);
    padding: var(--r-pad-sm);
  }
}
</style>
