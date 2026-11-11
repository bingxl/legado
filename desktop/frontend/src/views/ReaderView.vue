<script setup lang="ts">
/**
 * 阅读器外壳。
 *
 * 一次「阅读会话」里与书无关的那部分都在这里：路由、离开守卫、全屏态、
 * 词典浮层、快捷键归属。单本书的加载/渲染/进度/目录/朗读整块在
 * `components/reader/ReaderPane.vue` 里——它才是可以被渲染两份的东西
 * （M3 分屏就是再挂一个 pane，左栏 `:id`、右栏 `?split=`）。
 *
 * M2 只做拆分，**行为与拆分前逐字一致**：DOM 里 `.reader` 仍是根、
 * pane 内部的 `.bar / .stage / .text / .comic / .pdf / .nav / .chapter-progress`
 * 全部原样，所以 s3 / s6 / s13 / s22 / s23 / s24 的选择器都不需要改。
 */
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRoute, useRouter, onBeforeRouteLeave } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { bookshelfApi } from "@/api/bookshelf";
import { useBookshelfStore } from "@/stores/bookshelf";
import { useDictStore } from "@/stores/dict";
import { usePlatformStore } from "@/stores/platform";
import { useReaderLayoutStore } from "@/stores/readerLayout";
import { useBreakpoint } from "@/utils/breakpoint";
import { loadReaderPrefs } from "@/utils/readerPrefs";
import { smartBack } from "@/utils/nav";
import DictPopover from "@/components/DictPopover.vue";
import ReaderPane from "@/components/reader/ReaderPane.vue";
import SplitPicker from "@/components/reader/SplitPicker.vue";
import type { BookDetail } from "@/types";

const route = useRoute();
const router = useRouter();
const dict = useDictStore();
const platform = usePlatformStore();
const layout = useReaderLayoutStore();
const { width: viewportWidth } = useBreakpoint();

/** 左栏（单栏）那本书：路由 `:id` 是它的唯一来源，深链与书签语义不变。 */
const bookId = computed(() => Number(route.params.id || 0));
/** 详情页点某一章进来时带 `?index=N`，优先于上次阅读进度。 */
const startIndex = computed(() => {
  const want = Number(route.query.index);
  return Number.isFinite(want) && route.query.index !== undefined
    ? Math.trunc(want)
    : undefined;
});
/** AI 引用跳转带来的高亮片段（`?hl=`）。 */
const highlight = computed(() => String(route.query.hl || ""));

// ---------------- 分屏 ----------------

/**
 * 分屏状态完全由路由 query 表达：`?split=` 存在即分屏，`?split=0` 是「右栏空态」，
 * `?split=<id>` 是右栏已选书。
 *
 * 为什么不放内存 ref：分屏开关要能熬过整页刷新（重启后回到同一个阅读现场），
 * 而它一旦进路由就自动有了这个能力。**一律 replace**——分屏是视图状态，
 * 不该在历史栈里留一步，否则返回键要按两次才回详情页（`smartBack` 也依赖
 * `history.state.back`，replace 不会动它）。
 */
const splitRaw = computed(() => route.query.split);
/**
 * 分屏是否生效。移动端恒 false：两栏并排在手机上各剩不到 200px，
 * 而且安卓端 UI 与桌面本就该一致（那边没有并排概念）。
 */
const splitOpen = computed(() => splitRaw.value !== undefined && !platform.isMobile);
const splitBookId = computed(() => {
  const n = Number(splitRaw.value);
  return Number.isFinite(n) && n > 0 ? Math.trunc(n) : 0;
});

/** 当前活动栏：只有它响应键盘、写进度、弹词典浮层。 */
const activePane = ref<"left" | "right">("left");

/**
 * 左栏是否活动。
 *
 * 右栏还是空态（选书面板）时没有可交互的窗格，左栏必须继续算活动——
 * 否则「开了分屏但还没选书」的阶段键盘方向键与 Esc 全是死的。
 */
const leftActive = computed(
  () => !splitOpen.value || !splitBookId.value || activePane.value === "left",
);

/** 左右分栏比例（左栏占的份数），拖动分隔条时改它。 */
const splitRatio = ref(0.5);

/** 窗口太窄时两栏都没法读：自动收回单栏（设计里定的 900px 门槛）。 */
const MIN_SPLIT_WIDTH = 900;

function replaceQuery(patch: Record<string, string | undefined>) {
  const q: Record<string, string> = {};
  for (const [k, v] of Object.entries(route.query)) {
    if (typeof v === "string") q[k] = v;
  }
  for (const [k, v] of Object.entries(patch)) {
    if (v === undefined) delete q[k];
    else q[k] = v;
  }
  return router.replace({ path: route.path, query: q });
}

/** 开分屏：右栏先空着，让用户自己挑书（不猜他想读哪本）。 */
function openSplit() {
  if (platform.isMobile) return;
  // 窗口本身就不够宽时直接说清楚，别开了又立刻被自动收回（看起来像坏了）。
  if (viewportWidth.value < MIN_SPLIT_WIDTH) {
    ElMessage.info(`窗口太窄，并排阅读需要至少 ${MIN_SPLIT_WIDTH}px 宽`);
    return;
  }
  activePane.value = "right";
  void replaceQuery({ split: "0" });
}

/** 右栏选中一本书。 */
function pickSplitBook(id: number) {
  activePane.value = "right";
  void replaceQuery({ split: String(id) });
}

/** 关掉右栏，回单栏。 */
function closeSplit() {
  if (!splitOpen.value) return;
  activePane.value = "left";
  void replaceQuery({ split: undefined });
}

// 窄窗口自动收：拖窗口变窄时右栏已经挤成一条缝，留着不如退出。
watch(viewportWidth, (w) => {
  if (splitOpen.value && !platform.isMobile && w < MIN_SPLIT_WIDTH) closeSplit();
});

// 换左栏那本书时分屏一并关掉：`?split` 是跟着这个阅读现场走的，
// 换书后还挂着上一个现场的右栏会让人莫名其妙。
watch(bookId, () => {
  if (splitOpen.value) void replaceQuery({ split: undefined });
  activePane.value = "left";
});

/**
 * 拖分隔条改比例。
 *
 * 为什么不用 `setPointerCapture`：本机 WebView2 里它不生效（实测指针一离开
 * 6px 的分隔条就收不到 pointermove，拖动只挪 2px 就"断线"）。
 * 改成拖拽期间铺一层透明遮罩接管指针：遮罩在父文档里，能盖住正文，
 * 也能盖住 PDF 那个 iframe（iframe 内的指针事件不会冒泡到父文档，
 * 这正是当初想用 capture 的原因）。
 */
const readerRef = ref<HTMLElement | null>(null);
const dragging = ref(false);
let dragRect = { left: 0, width: 1 };

function startDrag(e: PointerEvent) {
  const host = readerRef.value;
  if (!host) return;
  const r = host.getBoundingClientRect();
  dragRect = { left: r.left, width: r.width };
  dragging.value = true;
  e.preventDefault();
}

function onDragMove(e: PointerEvent) {
  if (!dragging.value) return;
  const ratio = (e.clientX - dragRect.left) / dragRect.width;
  // 20% 下限：再窄正文就只剩几个字一行，拖不回来比拖不准更难受。
  splitRatio.value = Math.min(0.8, Math.max(0.2, ratio));
}

function endDrag() {
  dragging.value = false;
}

/** 各栏已加载的书（按 id 去重），离开时用来做「试读是否入架」的询问。 */
const openedBooks = ref<BookDetail[]>([]);
function onPaneLoaded(b: BookDetail) {
  const at = openedBooks.value.findIndex((x) => x.id === b.id);
  if (at >= 0) openedBooks.value[at] = b;
  else openedBooks.value.push(b);
}

/**
 * 换书时丢掉上一本的记录，避免离开时对已经不看的那本弹询问；
 * 同时把分屏一并关掉——`?split` 属于这个阅读现场，换书后还挂着右栏会让人
 * 莫名其妙（右栏还是上一本书，左栏已经换了）。
 */
watch(bookId, () => {
  openedBooks.value = [];
  if (splitOpen.value) void replaceQuery({ split: undefined });
  activePane.value = "left";
});

/** 返回书籍详情页：阅读器的上一级恒为详情页，不能靠 history.back()
 * （一路切着 tab 进来时会退回上一个 tab）。 */
async function goBack() {
  // 先把 split 从 query 里摘掉再跳：否则从详情页前进回到阅读器时
  // 右栏会拿一个"上一次会话"的书自己复活，看起来像幽灵窗格。
  if (splitOpen.value) await closeSplit();
  smartBack(router, `/book/${bookId.value}`, {
    mustMatch: `/book/${bookId.value}`,
  });
}

/**
 * 离开阅读器时，若这本书只是试读（发现/搜索点开、从未加入书架），
 * 询问一次是否加入书架——这就是「读完再问」的落点。
 *
 * 这套询问默认**关闭**（设置 → 阅读 → 返回时提示加入书架）：从搜索/发现
 * 点开书大多只是随手看两章，退出时被拦一次属于打断。开关打开后才弹。
 * 书籍与漫画共用这个阅读器，所以一处判定同时覆盖两者。
 *
 * 放在路由离开守卫里而不是 onBeforeUnmount：卸载时组件已经在拆，
 * 弹不出对话框，也拿不到用户的选择。取消/关闭一律放行，
 * 只表达「要不要入架」，不拦人。
 */
let shelfPrompting = false;
onBeforeRouteLeave(async () => {
  // 每次都现读：用户可能在设置页刚改完又回到这里，不必重启应用。
  if (!loadReaderPrefs().promptAddToShelf) return true;
  // 分屏时两栏可能都是试读，但每本最多问一次；分屏选书限定书架内，
  // 所以实际上只会问左栏那本。
  const pending = openedBooks.value.filter((b) => !b.inShelf);
  if (!pending.length) return true;
  // 连点返回时不要叠出多个对话框：后一次直接等前一次的结果。
  if (shelfPrompting) return false;
  shelfPrompting = true;
  const added: BookDetail[] = [];
  try {
    for (const b of pending) {
      try {
        await ElMessageBox.confirm(
          `《${b.name}》还不在书架中，要把它加入书架吗？`,
          "加入书架",
          {
            confirmButtonText: "加入书架",
            cancelButtonText: "暂不加入",
            type: "info",
            closeOnClickModal: false,
          },
        );
        added.push(b);
      } catch {
        // 取消/关闭：只跳过这一本，不拦人
      }
    }
  } finally {
    shelfPrompting = false;
  }
  if (!added.length) return true;

  for (const b of added) {
    try {
      await bookshelfApi.putOnShelf(b.id);
      b.inShelf = true;
      ElMessage.success(`《${b.name}》已加入书架`);
    } catch (e) {
      // 入架失败不该扣住用户：书还在库里，下次从详情页也能加。
      ElMessage.error((e as Error).message);
    }
  }
  void useBookshelfStore().loadBooks();
  return true;
});

onMounted(() => {
  // 全屏态要跟窗口对账：用户可能用系统快捷键退出，那条路不经过我们的按钮。
  layout.attach();
  void layout.sync();
  // 词库安装进度是全局的：用户可能停在阅读器里等汉英包下完。
  dict.attach();
});

onBeforeUnmount(() => {
  layout.detach();
  // 离开阅读器必须退出全屏，否则回到书架还是满屏、左侧栏也回不来。
  // force=true：即使此刻正在切换也要把状态压回去，离场不留中间态。
  void layout.setFullscreen(false, true);
  // 浮层与取词模式属于本页状态，离开就复位；安装进度留在 store 里继续。
  dict.close();
  dict.setPicking(false);
});
</script>

<template>
  <div ref="readerRef" class="reader" :class="{ 'is-split': splitOpen }">
    <!-- 左栏：单栏时它是唯一窗格，分屏时是主栏。 -->
    <ReaderPane
      :book-id="bookId"
      :start-index="startIndex"
      :highlight="highlight"
      :active="leftActive"
      :compact="splitOpen"
      :style="splitOpen ? { flex: String(splitRatio) } : undefined"
      @back="goBack"
      @loaded="onPaneLoaded"
      @activate="activePane = 'left'"
      @split="openSplit"
      @escape="closeSplit"
    />

    <template v-if="splitOpen">
      <div
        class="splitter"
        data-reader="splitter"
        role="separator"
        aria-orientation="vertical"
        @pointerdown="startDrag"
      />
      <!-- 右栏默认空着（不猜用户想读哪本），由选书面板填上。 -->
      <SplitPicker
        v-if="!splitBookId"
        :style="{ flex: String(1 - splitRatio) }"
        @pick="pickSplitBook"
        @cancel="closeSplit"
      />
      <ReaderPane
        v-else
        :key="splitBookId"
        :book-id="splitBookId"
        :active="activePane === 'right'"
        compact
        :style="{ flex: String(1 - splitRatio) }"
        @close="closeSplit"
        @loaded="onPaneLoaded"
        @activate="activePane = 'right'"
        @escape="closeSplit"
      />
    </template>

    <!-- 拖分隔条时的透明遮罩：接管指针，兼防止拖动中选中正文/点到 iframe -->
    <div
      v-if="dragging"
      class="split-veil"
      data-reader="split-veil"
      @pointermove="onDragMove"
      @pointerup="endDrag"
      @pointercancel="endDrag"
    />

    <!-- 取词浮层：桌面端贴在选区旁，移动端是底部卡片（由组件内部判定）。
         放在外壳里而不是窗格里：全局只有一个，分屏时也不该出现两份。 -->
    <DictPopover
      :visible="dict.visible"
      :loading="dict.loading"
      :error="dict.error"
      :result="dict.result"
      :anchor="dict.anchor"
      :mobile="platform.isMobile"
      @close="dict.close()"
      @lookup="(w: string) => dict.lookup(w)"
      @play="(w: string) => dict.speak(w)"
    />
  </div>
</template>

<style scoped>
/* 外壳只负责「窗格往哪儿摆」：单栏是一列（由 .pane 自己 flex:1 撑满），
   分屏时改成一行两列 + 中间可拖的分隔条。 */
.reader {
  position: relative;
  display: flex;
  flex-direction: column;
  height: 100%;
  min-width: 0;
  min-height: 0;
}
.reader.is-split {
  flex-direction: row;
}
.splitter {
  flex: none;
  width: 6px;
  cursor: col-resize;
  background: #eef0f3;
  border-left: 1px solid #e5e7eb;
  border-right: 1px solid #e5e7eb;
  touch-action: none;
}
.splitter:hover {
  background: #d8dde4;
}
/* 拖拽期间盖住整个阅读区：接管指针 + 阻止拖动中选中正文 */
.split-veil {
  position: absolute;
  inset: 0;
  z-index: 30;
  cursor: col-resize;
  background: transparent;
  touch-action: none;
}
</style>
