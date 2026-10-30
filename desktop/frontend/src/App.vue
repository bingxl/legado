<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";

import { useBookshelfStore } from "@/stores/bookshelf";
import { useCacheStore, jobPercent } from "@/stores/cache";
import { useSourceDebugStore } from "@/stores/sourceDebug";
import { useTtsStore } from "@/stores/tts";
import { onImportProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";
import TtsBar from "@/components/TtsBar.vue";

const router = useRouter();
const shelf = useBookshelfStore();
const tts = useTtsStore();
const cache = useCacheStore();
const progress = ref<ProgressPayload | null>(null);

const menus = [
  { path: "/", label: "书架", icon: "📚" },
  { path: "/explore", label: "发现", icon: "🧭" },
  { path: "/search", label: "搜索", icon: "🔍" },
  { path: "/cache", label: "缓存", icon: "🗂️" },
  { path: "/sources", label: "书源", icon: "🧩" },
  { path: "/webdav", label: "WebDAV", icon: "☁️" },
];

onMounted(() => {
  shelf.refresh();
  // 缓存进度是后台任务：订阅放在外壳里，页面切换不会丢进度。
  // 订阅失败（运行时还没注入）不能影响其它初始化，因此单独兜住。
  try {
    cache.attach();
  } catch {
    /* 事件订阅是增强能力，失败时由 store 的轮询兜底 */
  }
  // 书源调试的输出同理：一次调试要几十秒，切页面不能把日志弄丢。
  try {
    useSourceDebugStore().attach();
  } catch {
    /* 同上 */
  }
  cache
    .refreshJobs()
    .then(() => {
      if (cache.runningJobs.length) cache.ensurePolling();
    })
    .catch(() => {});
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
      <div class="brand"><img class="brand-icon" src="/appicon.svg" alt="" />Legado</div>
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

    <div class="main-col">
      <main class="content">
        <div v-if="progress" class="progress-bar">
          导入中 {{ progress.done }}/{{ progress.total }} — {{ progress.current }}
        </div>
        <!-- 缓存任务进度：脱离具体页面常驻，点一下回到缓存管理页 -->
        <div
          v-for="job in cache.runningJobs"
          :key="job.bookId"
          class="progress-bar cache-bar"
        >
          <span class="cache-text">
            缓存《{{ job.bookName }}》 {{ job.done + job.failed }}/{{ job.total }}（{{ jobPercent(job) }}%）
            <template v-if="job.message"> — {{ job.message }}</template>
          </span>
          <span class="cache-spacer" />
          <button class="cache-link" @click="router.push('/cache')">查看</button>
          <button class="cache-link" @click="cache.cancel(job.bookId)">取消</button>
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

      <!-- 朗读播放条常驻在外壳里，离开阅读器也能继续听/控制 -->
      <TtsBar v-if="tts.isActive" />
    </div>
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
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 18px;
  font-weight: 700;
  margin-bottom: 20px;
  padding-left: 8px;
}
.brand-icon {
  width: 22px;
  height: 22px;
  border-radius: 6px;
  flex: none;
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
.main-col {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}
.content {
  flex: 1;
  min-height: 0;
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
.cache-bar {
  display: flex;
  align-items: center;
  gap: 10px;
  background: #f5f7ff;
  border-bottom-color: #e0e7ff;
  color: #3730a3;
}
.cache-text {
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.cache-spacer {
  flex: 1;
}
.cache-link {
  flex: none;
  padding: 0;
  border: none;
  background: transparent;
  font-size: 12px;
  color: #4338ca;
  cursor: pointer;
}
.cache-link:hover {
  text-decoration: underline;
}
</style>
