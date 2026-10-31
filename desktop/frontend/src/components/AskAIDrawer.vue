<script setup lang="ts">
/**
 * 阅读器里的「问 AI」抽屉。
 *
 * 提问上下文取当前章（后端按整本书召回，这里只负责把入口做得顺手）：
 * 用户读到一半有疑问，不必离开正文就能问。
 */
import { computed } from "vue";
import { useRouter } from "vue-router";

import ChatPanel from "@/components/ChatPanel.vue";
import type { AIRefPayload } from "@/api/events";
import { citeFragment } from "@/utils/format";

const props = defineProps<{
  modelValue: boolean;
  bookId: number;
  bookName: string;
}>();

const emit = defineEmits<{
  (e: "update:modelValue", v: boolean): void;
}>();

const router = useRouter();

const open = computed({
  get: () => props.modelValue,
  set: (v: boolean) => emit("update:modelValue", v),
});

/** 抽屉里点引用：直接在当前阅读器跳章（不出抽屉也不跳页）。 */
function openCite(ref: AIRefPayload) {
  open.value = false;
  router.push({
    name: "reader",
    params: { id: String(props.bookId) },
    query: {
      index: String(Math.max(0, ref.chapterIdx)),
      hl: citeFragment(ref.excerpt),
    },
  });
}
</script>

<template>
  <el-drawer
    v-model="open"
    :title="`问 AI · ${bookName || '这本书'}`"
    direction="rtl"
    size="440px"
    class="ask-drawer"
  >
    <ChatPanel
      v-if="open"
      :book-id="bookId"
      compact
      class="panel"
      @cite="openCite"
    />
  </el-drawer>
</template>

<style scoped>
.panel {
  height: 100%;
}
</style>
