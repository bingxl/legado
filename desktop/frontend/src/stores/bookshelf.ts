/**
 * 书架状态。
 *
 * 约定：store 只做「数据持有 + 调用 src/api」，不直接引用 bindings，
 * 也不掺杂具体 UI 交互，保证状态层可独立测试。
 */
import { defineStore } from "pinia";
import { ref, computed } from "vue";

import { bookshelfApi } from "@/api/bookshelf";
import type { BookBrief, BookGroupView } from "@/types";

export const useBookshelfStore = defineStore("bookshelf", () => {
  const groups = ref<BookGroupView[]>([]);
  const books = ref<BookBrief[]>([]);
  const activeGroup = ref<number>(0); // 0 表示全部
  const loading = ref(false);
  const keyword = ref("");

  /** 按关键词过滤后的书籍（本地即时过滤，无需回后端）。 */
  const visibleBooks = computed(() => {
    const k = keyword.value.trim().toLowerCase();
    if (!k) return books.value;
    return books.value.filter(
      (b) =>
        b.name.toLowerCase().includes(k) || b.author.toLowerCase().includes(k),
    );
  });

  async function loadGroups() {
    groups.value = await bookshelfApi.listGroups();
  }

  async function loadBooks() {
    loading.value = true;
    try {
      books.value = await bookshelfApi.listBooks(activeGroup.value);
    } finally {
      loading.value = false;
    }
  }

  /** 切换分组并刷新列表。 */
  async function selectGroup(groupId: number) {
    activeGroup.value = groupId;
    await loadBooks();
  }

  async function refresh() {
    await Promise.all([loadGroups(), loadBooks()]);
  }

  async function removeBook(id: number) {
    await bookshelfApi.deleteBook(id);
    await loadBooks();
  }

  return {
    groups,
    books,
    activeGroup,
    loading,
    keyword,
    visibleBooks,
    loadGroups,
    loadBooks,
    selectGroup,
    refresh,
    removeBook,
  };
});
