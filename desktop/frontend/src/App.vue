<script setup lang="ts">
import { onMounted, ref } from "vue";
import { useRouter } from "vue-router";

import { useBookshelfStore } from "@/stores/bookshelf";
import { useAIChatStore } from "@/stores/aiChat";
import { useAIIndexStore } from "@/stores/aiIndex";
import { useCacheStore, jobPercent } from "@/stores/cache";
import { usePlatformStore } from "@/stores/platform";
import { useSourceDebugStore } from "@/stores/sourceDebug";
import { useTtsStore } from "@/stores/tts";
import { onImportProgress } from "@/api/events";
import type { ProgressPayload } from "@/api/events";
import TtsBar from "@/components/TtsBar.vue";

const router = useRouter();
const shelf = useBookshelfStore();
const tts = useTtsStore();
const cache = useCacheStore();
const platform = usePlatformStore();
const progress = ref<ProgressPayload | null>(null);

/**
 * 菜单分为两档：桌面侧边栏放全量，移动端底部 Tab 只放 5 个主入口。
 *
 * 安卓端一共 9 个功能页，全塞进底部 Tab 会挤到每个不到 60px 宽，
 * 手指点不准；所以按 legado 安卓端的做法，把低频功能收进「我的」。
 * 两端的功能集合完全一致，只是入口深度不同。
 */
const menus = [
  { path: "/", label: "书架", icon: "📚" },
  { path: "/explore", label: "发现", icon: "🧭" },
  { path: "/search", label: "搜索", icon: "🔍" },
  { path: "/sources", label: "书源", icon: "🧩" },
  { path: "/replace", label: "替换", icon: "✂️" },
  { path: "/subscriptions", label: "订阅", icon: "🔗" },
  { path: "/cache", label: "缓存", icon: "🗂️" },
  { path: "/ai", label: "AI", icon: "💬" },
  { path: "/webdav", label: "WebDAV", icon: "☁️" },
  { path: "/settings", label: "设置", icon: "⚙️" },
];

/** 移动端底部 Tab：前四个主入口 + 「我的」。 */
const mobileTabs = [
  { path: "/", label: "书架", icon: "📚" },
  { path: "/explore", label: "发现", icon: "🧭" },
  { path: "/search", label: "搜索", icon: "🔍" },
  { path: "/sources", label: "书源", icon: "🧩" },
  { path: "/settings", label: "我的", icon: "⚙️" },
];

/** 侧栏高亮：精确匹配。9 个入口各自独立，不能互相点亮。 */
function isActive(path: string): boolean {
  return router.currentRoute.value.path === path;
}

/**
 * 底部 Tab 高亮：带分组。
 *
 * 移动端只有 5 个 Tab，替换/订阅/缓存/WebDAV 收在「我的」下，
 * 进到这些子页时仍要点亮「我的」，否则用户会以为迷路。
 * 这个分组**只用于 Tab**——侧栏已经把 9 个入口平铺出来了，
 * 套用同一逻辑会让「缓存」和「设置」同时高亮。
 */
const MY_SUB_PAGES = ["/replace", "/subscriptions", "/cache", "/webdav"];
function isTabActive(path: string): boolean {
  const cur = router.currentRoute.value.path;
  if (path === "/settings") return cur === "/settings" || MY_SUB_PAGES.includes(cur);
  return cur === path;
}

async function toggleLayout() {
  await platform.setOverride(platform.isMobile ? "desktop" : "android");
}

onMounted(async () => {
  // 平台判定要最先做：布局分支依赖它，晚一步会先闪一帧桌面侧边栏。
  await platform.init();
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
  // AI 索引也是后台长任务：订阅放在外壳里，离开详情页后进度依然在更新。
  try {
    useAIIndexStore().attach();
  } catch {
    /* 同上 */
  }
  // 流式回答同理：切走页面再回来，回答应该还在。
  try {
    useAIChatStore().attach();
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
  <div v-if="platform.ready" class="app-shell" :class="{ 'is-mobile': platform.isMobile }">
    <aside v-if="!platform.isMobile" class="sidebar">
      <div class="brand"><img class="brand-icon" src="/appicon.svg" alt="" />Legado</div>
      <nav>
        <button
          v-for="m in menus"
          :key="m.path"
          class="nav-item"
          :class="{ active: isActive(m.path) }"
          @click="router.push(m.path)"
        >
          <span class="icon">{{ m.icon }}</span>
          <span>{{ m.label }}</span>
        </button>
      </nav>
      <div class="sidebar-footer">
        <div>共 {{ shelf.books.length }} 本</div>
        <!--
          布局预览开关：默认只在桌面端出现。
          安卓端 UI 的适配要在 Windows 上看效果，每次装 APK 太慢，
          一键切到移动端外壳即可用同一套代码验证。
        -->
        <button class="layout-switch" @click="toggleLayout">
          预览移动端布局
        </button>
      </div>
    </aside>

    <div class="main-col">
      <!--
        覆盖提示条：说明当前外壳不是真机判定出来的，并给出一键还原。
        没有它的话，在桌面端切成移动布局后刷新，会以为「安卓端就是这样」而忘记切回。
      -->
      <div v-if="platform.overridden" class="override-bar">
        <span>
          {{ platform.isMobile ? "移动端" : "桌面端" }}布局预览中（非真机判定）
        </span>
        <span class="cache-spacer" />
        <button class="cache-link" @click="toggleLayout">
          切回{{ platform.isMobile ? "桌面" : "移动" }}布局
        </button>
      </div>
      <main
        class="content"
        :style="platform.isMobile ? { paddingTop: `${platform.safeArea.top}px` } : undefined"
      >
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

      <!--
        移动端底部 Tab：桌面端走左侧栏，这里不渲染。
        padding-bottom 用后端给的安全区高度，避免被系统手势条压住。
      -->
      <nav
        v-if="platform.isMobile"
        class="tabbar"
        :style="{ paddingBottom: `${platform.safeArea.bottom}px` }"
      >
        <button
          v-for="m in mobileTabs"
          :key="m.path"
          class="tab-item"
          :class="{ active: isTabActive(m.path) }"
          @click="router.push(m.path)"
        >
          <span class="tab-icon">{{ m.icon }}</span>
          <span class="tab-label">{{ m.label }}</span>
        </button>
      </nav>
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
/* 布局预览开关：弱化成普通文字大小，避免和导航项抢视觉重心 */
.layout-switch {
  margin-top: 6px;
  margin-left: -4px;
  padding: 4px;
  border: none;
  background: transparent;
  color: #9ca3af;
  font-size: 12px;
  cursor: pointer;
}
.layout-switch:hover {
  color: #4338ca;
  text-decoration: underline;
}
/* 覆盖提示条：只在预览状态下出现，用醒目的琥珀色区分于进度条 */
.override-bar {
  flex: none;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 6px 16px;
  background: #fefce8;
  color: #a16207;
  font-size: 12px;
  border-bottom: 1px solid #fde68a;
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

/* ── 移动端外壳：底部 Tab 替代左侧栏 ────────────────────── */
.tabbar {
  flex: none;
  display: flex;
  background: #fff;
  border-top: 1px solid #e5e7eb;
}
.tab-item {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
  padding: 6px 2px;
  border: none;
  background: transparent;
  cursor: pointer;
  color: #6b7280;
  /* 移动端点击不要出现灰色高亮块 */
  -webkit-tap-highlight-color: transparent;
}
.tab-item.active {
  color: #4338ca;
  font-weight: 600;
}
.tab-icon {
  font-size: 18px;
  line-height: 1;
}
.tab-label {
  font-size: 10px;
  line-height: 1.2;
  white-space: nowrap;
}
/* ── 移动端横切适配 ─────────────────────────────────────────
   现有视图最初按桌面 1200px 宽写，逐个改一遍成本很高。
   这里只收两类最常见的窄屏溢出：内联固定宽度的控件、不换行的工具栏。
   更细的差异仍由各视图自己的 @media 处理，避免全局规则越写越宽。

   之所以用 !important：视图里大量 `style="width: 300px"` 是内联样式，
   优先级高于任何选择器，只能靠 !important 覆盖。
   这里只压 max-width（上限），不影响小尺寸控件。 */
@media (max-width: 640px) {
  /* 工具栏换行：不换行的话 flex 会把按钮压成几十像素宽，文字截断到看不清。
     这些类是各视图 scoped 样式里的，但全局规则仍按类名命中——
     scoped 只影响视图自己那份样式的作用域。 */
  .toolbar,
  .bar,
  .head {
    flex-wrap: wrap;
  }
  .el-input,
  .el-select,
  .el-input-number {
    max-width: 100% !important;
  }
  /* 弹窗默认带固定宽与外边距，窄屏下会露出两侧空白且按钮被挤出可视区 */
  .el-dialog {
    width: 100% !important;
    margin: 0 !important;
  }
  /* 触控目标：桌面 12px 的行高在手机上点不准 */
  .el-button {
    min-height: 32px;
  }
}
/* 内容区在移动端交给系统滚动惯性，避免卡顿 */
.is-mobile .content {
  -webkit-overflow-scrolling: touch;
}
</style>
