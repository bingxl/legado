<script setup lang="ts">
/**
 * AI 问答页（`/ai?book=<id>`）。
 *
 * 入口：桌面侧栏「AI」、书籍详情页的 AI 面板、阅读器抽屉的「展开」。
 * 没有 book 参数时先让用户选一本书——AI 问答必须绑定一本书，
 * 否则检索不到任何资料，只会变成通用聊天。
 */
import { computed, onMounted, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";

import ChatPanel from "@/components/ChatPanel.vue";
import type { AIRefPayload } from "@/api/events";
import { citeFragment } from "@/utils/format";
import { useBookshelfStore } from "@/stores/bookshelf";

const route = useRoute();
const router = useRouter();
const shelf = useBookshelfStore();

const picked = ref(0);

const bookId = computed(() => Number(route.query.book || 0));
const book = computed(() => shelf.books.find((b) => b.id === bookId.value) ?? null);

function choose(id: number) {
  router.replace({ path: "/ai", query: { book: String(id) } });
}

/** 点引用：跳到阅读器对应章节，并带上高亮片段。 */
function openCite(ref: AIRefPayload) {
  router.push({
    name: "reader",
    params: { id: String(bookId.value) },
    query: {
      index: String(Math.max(0, ref.chapterIdx)),
      // 只带片段开头：太长会超 URL 长度，也没必要。
      hl: citeFragment(ref.excerpt),
    },
  });
}

watch(bookId, () => {
  picked.value = bookId.value;
});

onMounted(async () => {
  if (!shelf.books.length) await shelf.loadBooks().catch(() => {});
  picked.value = bookId.value;
});
</script>

<template>
  <div class="ai-view">
    <header class="head">
      <h1 class="title">AI 问答</h1>
      <span v-if="book" class="sub">{{ book.name }}</span>
      <div class="fill" />
      <el-button
        v-if="book"
        size="small"
        @click="router.push({ name: 'book', params: { id: String(book.id) } })"
      >书籍详情</el-button>
    </header>

    <div v-if="!bookId" class="picker">
      <p class="hint">选一本书开始提问。回答只依据书里的内容，并标注出处。</p>
      <el-select
        v-model="picked"
        filterable
        placeholder="选择一本书"
        class="select"
        data-ai="book-picker"
        @change="choose"
      >
        <el-option
          v-for="b in shelf.books"
          :key="b.id"
          :label="b.name"
          :value="b.id"
        />
      </el-select>
      <p v-if="!shelf.books.length" class="hint">书架还是空的，先导入或搜索一本书。</p>
    </div>

    <ChatPanel
      v-else
      :key="bookId"
      :book-id="bookId"
      class="panel"
      @cite="openCite"
    />
  </div>
</template>

<style scoped>
.ai-view {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  padding: 16px 20px 20px;
  background: #fff;
}
.head {
  display: flex;
  align-items: baseline;
  gap: 10px;
  flex: none;
  margin-bottom: 12px;
}
.title {
  font-size: 18px;
  font-weight: 600;
  margin: 0;
  color: rgba(0, 0, 0, 0.87);
}
.sub {
  font-size: 13px;
  color: rgba(0, 0, 0, 0.45);
}
.fill {
  flex: 1;
}
.picker {
  display: flex;
  flex-direction: column;
  gap: 10px;
  max-width: 420px;
}
.select {
  width: 100%;
}
.hint {
  font-size: 13px;
  line-height: 1.7;
  color: rgba(0, 0, 0, 0.55);
  margin: 0;
}
.panel {
  flex: 1;
  min-height: 0;
}
</style>
