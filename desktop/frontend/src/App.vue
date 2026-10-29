<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";

import { useBookshelfStore } from "@/stores/bookshelf";
import { onImportProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";

const router = useRouter();
const shelf = useBookshelfStore();
const progress = ref<ProgressPayload | null>(null);

const menus = [
  { path: "/", label: "书架", icon: "📚" },
  { path: "/explore", label: "发现", icon: "🧭" },
  { path: "/search", label: "搜索", icon: "🔍" },
  { path: "/sources", label: "书源", icon: "🧩" },
  { path: "/webdav", label: "WebDAV", icon: "☁️" },
];

onMounted(() => {
  shelf.refresh();
  // 后端推送的导入进度：完成后自动刷新书架。
  onImportProgress((data) => {
    progress.value = data;
    if (data.done >= data.total) {
      shelf.loadBooks();
      setTimeout(() => (progress.value = null), 1500);
    }
  });
});
</script>

<template>
  <div class="app-shell">
    <aside class="sidebar">
      <div class="brand">Legado</div>
      <nav>
        <button
          v-for="m in menus"
          :key="m.path"
          class="nav-item"
          :class="{ active: router.currentRoute.value.path === m.path }"
          @click="router.push(m.path)"
        >
          <span class="icon">{{ m.icon }}</span>
          <span>{{ m.label }}</span>
        </button>
      </nav>
      <div class="sidebar-footer">
        共 {{ shelf.books.length }} 本
      </div>
    </aside>

    <main class="content">
      <div v-if="progress" class="progress-bar">
        导入中 {{ progress.done }}/{{ progress.total }} — {{ progress.current }}
      </div>
      <!--
        发现页缓存起来：进详情/阅读器再返回时，展开的书源、分类书单与滚动位置都还在。
        其它页面不缓存，避免书架、书源列表显示过期数据。
      -->
      <router-view v-slot="{ Component }">
        <keep-alive :include="['ExploreView']">
          <component :is="Component" />
        </keep-alive>
      </router-view>
    </main>
  </div>
</template>

<style>
* {
  box-sizing: border-box;
}
html,
body,
#app {
  height: 100%;
  margin: 0;
}
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Microsoft YaHei",
    sans-serif;
  color: #1f2328;
  background: #f6f7f9;
}
</style>

<style scoped>
.app-shell {
  display: flex;
  height: 100%;
}
.sidebar {
  width: 180px;
  flex: none;
  background: #fff;
  border-right: 1px solid #e5e7eb;
  display: flex;
  flex-direction: column;
  padding: 16px 12px;
}
.brand {
  font-size: 18px;
  font-weight: 700;
  margin-bottom: 20px;
  padding-left: 8px;
}
.nav-item {
  display: flex;
  align-items: center;
  gap: 10px;
  width: 100%;
  padding: 9px 10px;
  margin-bottom: 4px;
  border: none;
  border-radius: 8px;
  background: transparent;
  cursor: pointer;
  font-size: 14px;
  color: #374151;
  text-align: left;
}
.nav-item:hover {
  background: #f3f4f6;
}
.nav-item.active {
  background: #eef2ff;
  color: #4338ca;
  font-weight: 600;
}
.icon {
  font-size: 15px;
}
.sidebar-footer {
  margin-top: auto;
  font-size: 12px;
  color: #9ca3af;
  padding-left: 8px;
}
.content {
  flex: 1;
  overflow: auto;
  display: flex;
  flex-direction: column;
}
.progress-bar {
  padding: 8px 16px;
  background: #fff7ed;
  color: #9a3412;
  font-size: 13px;
  border-bottom: 1px solid #fed7aa;
}
</style>
