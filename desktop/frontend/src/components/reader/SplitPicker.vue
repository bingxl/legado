<script setup lang="ts">
/**
 * 分屏右栏的空态：选一本要并排读的书。
 *
 * 为什么选书限定**书架内**：分屏后两栏都可能"不在书架"（从搜索/发现点开的试读），
 * 离开阅读器时的入架询问就要连着弹两次——限定书架内，那条老逻辑继续"最多问一次"。
 * 想并排读一本试读书，先入架。
 *
 * 允许两栏同一本书（用户明确要求的用法：同书不同章对照），所以这里**不过滤**
 * 已在左栏打开的书。进度写入的冲突由窗格的 active 约定解决（只有活动栏写）。
 */
import { computed, onMounted, ref } from "vue";

import { useBookshelfStore } from "@/stores/bookshelf";

const emit = defineEmits<{
  /** 选中一本书作为右栏。 */
  (e: "pick", bookId: number): void;
  /** 放弃分屏，回到单栏。 */
  (e: "cancel"): void;
}>();

const shelf = useBookshelfStore();
const keyword = ref("");

/** 按书名/作者做本地过滤（与书架页同一套判定，不额外打后端）。 */
const visible = computed(() => {
  const k = keyword.value.trim().toLowerCase();
  if (!k) return shelf.books;
  return shelf.books.filter(
    (b) => b.name.toLowerCase().includes(k) || b.author.toLowerCase().includes(k),
  );
});

onMounted(() => {
  // 从详情页/深链直接进来时书架可能还没加载过。
  if (!shelf.books.length) void shelf.loadBooks();
});
</script>

<template>
  <section class="split-picker" data-reader="split-picker">
    <header class="sp-head">
      <span class="sp-title">并排阅读</span>
      <button class="sp-cancel" data-reader="split-cancel" @click="emit('cancel')">
        取消
      </button>
    </header>

    <div class="sp-search">
      <el-input v-model="keyword" size="small" placeholder="搜索书名 / 作者" clearable />
    </div>

    <div class="sp-list">
      <button
        v-for="b in visible"
        :key="b.id"
        class="sp-item"
        :data-book="b.id"
        @click="emit('pick', b.id)"
      >
        <span class="sp-name">{{ b.name }}</span>
        <span class="sp-author">{{ b.author || "佚名" }}</span>
      </button>
      <p v-if="!visible.length" class="sp-empty">
        {{ shelf.books.length ? "没有匹配的书" : "书架还是空的" }}
      </p>
    </div>
  </section>
</template>

<style scoped>
.split-picker {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  background: #fafbfc;
  border-left: 1px solid #e5e7eb;
}
.sp-head {
  display: flex;
  align-items: center;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  border-bottom: 1px solid #e5e7eb;
  background: #fff;
}
.sp-title {
  font-weight: 600;
  color: #111827;
}
.sp-cancel {
  margin-left: auto;
  border: none;
  background: none;
  color: #6b7280;
  font-size: 13px;
  cursor: pointer;
}
.sp-cancel:hover {
  color: #111827;
}
.sp-search {
  padding: var(--r-pad-sm) var(--r-pad);
}
.sp-list {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
  padding: 0 var(--r-pad-sm) var(--r-pad);
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.sp-item {
  display: flex;
  align-items: baseline;
  gap: var(--r-gap-sm);
  width: 100%;
  padding: 8px 10px;
  border: none;
  border-radius: 6px;
  background: none;
  text-align: left;
  cursor: pointer;
  min-width: 0;
}
.sp-item:hover {
  background: #eef2f7;
}
.sp-name {
  flex: 1;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: #111827;
}
.sp-author {
  flex: none;
  max-width: 40%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  color: #9ca3af;
}
.sp-empty {
  margin: 24px 0 0;
  text-align: center;
  color: #9ca3af;
  font-size: 13px;
}
</style>
