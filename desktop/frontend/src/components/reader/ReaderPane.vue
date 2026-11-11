<script setup lang="ts">
/**
 * 单本书的阅读窗格。
 *
 * 从 `views/ReaderView.vue` 里整块搬来的单书逻辑（M2 纯重构，行为零变化）：
 * 加载详情/目录/正文、渲染（文本 / 漫画 / PDF）、进度条、目录、取词、朗读会话、
 * 缓存任务、全屏切换。**DOM 结构与类名完全保留**（`.bar` / `.stage` / `.text` /
 * `.comic` / `.pdf` / `.nav` / `.toc`），所以 s3 / s6 / s13 / s22 / s23 / s24
 * 的选择器一条都不用改。
 *
 * 搬出去的是「一本书自己的状态」：`book / chapters / content / index / 滚动位置 /
 * chapterPct / tocVisible`。这些都是组件内的单例 ref，留在外壳里就没法渲染两份
 * （M3 分屏会互相覆盖），所以它们跟着窗格走。
 *
 * 留在外壳（`ReaderView`）的是「一次阅读会话」级别的东西：路由与离开守卫、
 * 全屏态的挂载/对账、词典浮层、快捷键的归属判定。窗格通过 props / emits 与
 * 外壳通信，不直接读路由——右栏（M3）的 bookId 不在路由的 `:id` 里。
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { ElMessage, ElMessageBox } from "element-plus";

import { bookshelfApi } from "@/api/bookshelf";
import { readerApi } from "@/api/reader";
import { CacheScope, cacheApi } from "@/api/cache";
import { rawFileURL } from "@/api/system";
import { useBookDataStore } from "@/stores/bookData";
import { useBookshelfStore } from "@/stores/bookshelf";
import { jobPercent, useCacheStore } from "@/stores/cache";
import { useReaderLayoutStore } from "@/stores/readerLayout";
import { useTtsStore } from "@/stores/tts";
import { useDictStore } from "@/stores/dict";
import { domSegment } from "@/tts/domSegment";
import { segmentHTML } from "@/tts/offlineSegment";
import type { TtsSession } from "@/stores/tts";
import { percentFromScroll, scrollTopForPercent } from "@/utils/chapterProgress";
import { copyText } from "@/utils/clipboard";
import { comicImageURL } from "@/utils/media";
import { useReaderStyle } from "@/utils/readerPrefs";
import { wrapPlainTextAsParagraphs } from "@/utils/plainText";
import { usePlatformStore } from "@/stores/platform";
import AskAIDrawer from "@/components/AskAIDrawer.vue";
import ChapterProgress from "@/components/ChapterProgress.vue";
import type { BookDetail, ChapterContent, ChapterItem } from "@/types";

const props = withDefaults(
  defineProps<{
    /** 本栏阅读的书。窗格以它为准加载，不再读路由（右栏不从 `:id` 来）。 */
    bookId: number;
    /**
     * 是否当前活动栏。
     *
     * 单栏时恒真。分屏后：只有活动栏响应键盘、写阅读进度、弹词典，
     * 否则两栏会抢方向键、互相覆盖 `saveProgress`。
     */
    active?: boolean;
    /** 精简顶栏（分屏态用）。单栏时恒假，渲染与今天完全一致。 */
    compact?: boolean;
    /** 进入时定位的章节（详情页点某一章），不传则用上次阅读进度。 */
    startIndex?: number;
    /** 要高亮的片段（AI 引用跳转的 `?hl=`），只在左栏生效。 */
    highlight?: string;
  }>(),
  { active: true, compact: false, startIndex: undefined, highlight: "" },
);

const emit = defineEmits<{
  /** 返回详情页：路由跳转属于外壳的职责。 */
  (e: "back"): void;
  /** 本栏被用户碰了（点击/滚轮），外壳据此切换 active 栏。 */
  (e: "activate"): void;
  /** 左上角关闭本栏（仅分屏态渲染）。 */
  (e: "close"): void;
  /** 单栏顶栏点「分屏」：右栏怎么来的由外壳决定（要改路由 query）。 */
  (e: "split"): void;
  /**
   * Esc 在本栏的层级里没人接（浮层/取词/全屏都处理完了）。
   * 交给外壳继续往下退（关分屏），否则用户只能靠鼠标找按钮。
   */
  (e: "escape"): void;
  /** 详情加载完成，外壳拿去做出入架询问与标题展示。 */
  (e: "loaded", book: BookDetail): void;
}>();

const router = useRouter();
const tts = useTtsStore();
const cache = useCacheStore();
const bookData = useBookDataStore();
const platform = usePlatformStore();
const dict = useDictStore();
const layout = useReaderLayoutStore();
/** 字号/行距是全局共享的：分屏时两栏必须一致，否则观感割裂。 */
const style = useReaderStyle();

const book = ref<BookDetail | null>(null);
const chapters = ref<ChapterItem[]>([]);
const content = ref<ChapterContent | null>(null);
const index = ref(0);
const loading = ref(false);
const tocVisible = ref(false);
/** 目录倒序开关：连载追更时看最新章常用倒序。 */
const tocReversed = ref(false);
/**
 * 栏位（顶栏/底栏/进度条）是否展开。
 * 移动端本来就靠点屏幕中间切换；桌面端在**全屏时**才有这个开关，
 * 不进入全屏就恒显（见 chromeShown）。
 */
const chromeVisible = ref(true);
/**
 * 沉浸态：移动端恒真、桌面端由全屏开关决定。
 *
 * 两端共用这一个判定，`chromeShown` 才不会分成两套：
 * 移动端 `immersive` 恒为 true，退化成原来的 `chromeVisible`（行为一字未改）；
 * 桌面端非全屏时恒为 true（顶栏底栏常显），全屏后才可以点中间收起。
 */
const chromeShown = computed(() => !layout.immersive || chromeVisible.value);
const stageRef = ref<HTMLElement | null>(null);
/** 「问 AI」抽屉开关。 */
const askOpen = ref(false);
/** 已缓存的章节序号，用于目录里打标记。 */
const cachedIndexes = ref<Set<number>>(new Set());
/** 本章已读百分比（0~100），随正文滚动更新，底部进度条据此显示。 */
const chapterPct = ref(0);
/** 本章是否有可滚动范围：不足一屏时进度条置灰（没有可拖的区间）。 */
const chapterScrollable = ref(false);

/**
 * 本栏书籍的稳定 id。
 *
 * 组件卸载后 props 不再更新，但朗读会话仍会继续拉下一章、写进度；
 * 所有「离开后仍可能执行」的操作都读这个值，避免读到已被外壳清空的值。
 */
const boundBookId = ref(0);

/** 正文/漫画的滚动容器（二者互斥渲染，PDF 由 iframe 自己管）。 */
function scroller(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".text, .comic") ?? null;
}

/**
 * 用滚动位置刷新本章进度。
 *
 * el 允许由调用方传入（滚动事件里直接给 e.target）：滚动每帧都在触发，
 * 没必要每次都 querySelector 一遍。
 */
function syncChapterPct(el: HTMLElement | null = scroller()) {
  if (!el) return;
  chapterScrollable.value = el.scrollHeight - el.clientHeight > 0;
  chapterPct.value = percentFromScroll(
    el.scrollTop,
    el.scrollHeight,
    el.clientHeight,
  );
}

/**
 * 合并到下一帧再算进度。
 *
 * 漫画的图片是懒加载的，一章几十张图各来一次 load；窗口拖动改尺寸时也一样，
 * 每次都重算会白跑一轮布局。
 */
let pctQueued = false;
function queueSyncChapterPct() {
  if (pctQueued) return;
  pctQueued = true;
  requestAnimationFrame(() => {
    pctQueued = false;
    syncChapterPct();
  });
}

/** 全屏提示每次会话只弹一次：每切一次都弹就成了噪音。 */
let fullscreenHintShown = false;

/**
 * 切换全屏阅读（桌面端）。
 *
 * 窗口宽高变了，同一章的可滚动范围也就变了：只保留像素 scrollTop 会让人
 * 觉得"跳了一段"。所以记下**章内百分比**，等窗口尺寸稳定后按百分比落回去，
 * 换算复用进度条那一套（scrollTopForPercent），不引入第二套口径。
 */
async function toggleFullscreen() {
  // 安卓端没有窗口层：沉浸就是点中间收栏位，这里不参与（外接键盘发 F11 也一样）。
  if (platform.isMobile) return;
  const pct = chapterPct.value;
  await layout.toggle();
  if (layout.fullscreen && !fullscreenHintShown) {
    fullscreenHintShown = true;
    ElMessage.info("已进入全屏：Esc 或 F11 退出，点正文中间可收起顶栏");
  }
  await restorePctAfterResize(pct);
}

/**
 * 等窗口尺寸稳定后按百分比还原滚动位置。
 *
 * 全屏切换会连发多次 resize（窗口动画），固定 sleep 在慢机器上会算早。
 * 连续两次 scrollHeight 一致即认为稳定，最多等 8 轮（约 480ms）。
 */
async function restorePctAfterResize(pct: number) {
  let last = -1;
  for (let i = 0; i < 8; i++) {
    // 等一帧再看高度：sleep 写在这里而不是拆成循环外的等待，
    // 是因为高度可能在动画中途反复变。
    await new Promise((resolve) => setTimeout(resolve, 60));
    const el = scroller();
    if (!el) return; // PDF 由 iframe 自己管滚动，没有可还原的容器
    if (el.scrollHeight === last && i >= 2) {
      el.scrollTop = scrollTopForPercent(pct, el.scrollHeight, el.clientHeight);
      syncChapterPct(el);
      return;
    }
    last = el.scrollHeight;
  }
}

const isPdf = computed(() => book.value?.format === "pdf");
/** 漫画：本地漫画文件，或网络漫画源的章节图片流（后端已把 <img> 抽成 images）。 */
const isComic = computed(
  () => book.value?.format === "comic" || (content.value?.images?.length ?? 0) > 0,
);

/** 当前正在朗读的是不是这本书（含暂停）。 */
const readingThisBook = computed(
  () => tts.isActive && tts.bookId === boundBookId.value,
);
/** 只有纯文本类支持朗读；漫画无字、PDF 待 M2 的 pdf.js 文本层。 */
const canRead = computed(() => !!book.value && !isPdf.value && !isComic.value);

const cacheLabel = computed(() => {
  const job = cacheJob.value;
  if (job?.state === "running") return `缓存中 ${jobPercent(job)}%`;
  return "缓存";
});

const readLabel = computed(() => {
  if (!readingThisBook.value) return "▶ 朗读";
  if (tts.status === "playing" || tts.status === "preparing") return "⏸ 暂停";
  return "▶ 继续";
});

/** 复制书籍地址：网络书是详情页 URL，本地书是文件路径。 */
async function copyBookURL() {
  const url = book.value?.bookUrl;
  if (!url) {
    ElMessage.warning("这本书没有可复制的地址");
    return;
  }
  if (await copyText(url)) ElMessage.success("已复制书籍地址");
  else ElMessage.error("复制失败，请手动复制");
}

/**
 * 正文渲染用 HTML。
 *
 * 有的书源正文是一段带换行的纯文本（没有 `<p>`），直接 v-html 会折成一整面墙；
 * 这里按行补成段落（含标签的 HTML 原样通过，见 utils/plainText.ts）。
 */
const displayHTML = computed(() =>
  wrapPlainTextAsParagraphs(content.value?.html ?? ""),
);

/**
 * 高亮 AI 引用跳转带来的片段（`?hl=<片段开头>`）。
 *
 * 为什么不动 displayHTML：往 v-html 里插 `<mark>` 会与净化规则、TTS 切段
 * 相互干扰。这里在渲染完成后直接操作 DOM，只影响视觉，不改内容来源。
 * 切换章节时 DOM 会被整体替换，高亮自然消失，无需清理状态。
 *
 * 匹配时忽略空白：切片文本经过空白归一化（全角空格→普通空格、连续空白折叠），
 * 而正文渲染的是原始 HTML，同一句话两边的空白字符往往不同。
 * 直接 indexOf 会「明明有这段却高亮不上」，所以两边都去掉空白再比，
 * 再用下标映射还原真实位置。
 */
function highlightQuery() {
  // 复用朗读模块的 contentEl()：正文容器只有一个，别维护第二份选择器。
  const root = contentEl();
  if (!root) return;
  const needle = compactSpace(props.highlight);
  if (!needle) return;

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let node = walker.nextNode();
  while (node) {
    const text = node.nodeValue ?? "";
    if (compactSpace(text).includes(needle)) {
      const hit = locate(text, needle);
      if (hit) {
        const range = document.createRange();
        range.setStart(node, hit.start);
        range.setEnd(node, hit.end);
        const mark = document.createElement("mark");
        mark.className = "ai-hit";
        range.surroundContents(mark);
        // 即时滚动：平滑滚动在长章节里要滚好几秒，用户会以为没跳成功。
        mark.scrollIntoView({ block: "center" });
        return;
      }
    }
    node = walker.nextNode();
  }
}

/** 去掉全部空白字符（含全角空格、换行）。 */
function compactSpace(s: string): string {
  return s.replace(/\s+/g, "");
}

/** 在原始文本里定位「去空白后」的片段，返回原串下标区间。 */
function locate(text: string, compactNeedle: string): { start: number; end: number } | null {
  const map: number[] = [];
  const chars: string[] = [];
  for (let i = 0; i < text.length; i++) {
    if (/\s/.test(text[i])) continue;
    chars.push(text[i]);
    map.push(i);
  }
  const at = chars.join("").indexOf(compactNeedle);
  if (at < 0) return null;
  return { start: map[at], end: map[at + compactNeedle.length - 1] + 1 };
}

watch(
  () => content.value?.html,
  async () => {
    await nextTick();
    highlightQuery();
  },
);

/** 当前书的缓存任务（运行中时 toolbar 显示进度）。 */
const cacheJob = computed(() => cache.jobOf(boundBookId.value));
/** 本地书本身就是本地文件，缓存没有意义。 */
const canCache = computed(() => !!book.value && book.value.kind !== "local");

/** PDF 直读地址：本地路径经后端 /raw/ 路由暴露。 */
const pdfURL = computed(() =>
  book.value ? rawFileURL(book.value.bookUrl) : "",
);

async function loadMeta() {
  boundBookId.value = props.bookId;
  // 详情/目录走全局缓存：详情页刚拉过就直接复用，来回切换不重拉。
  book.value = await bookData.getBook(props.bookId);
  chapters.value = await bookData.getChapters(props.bookId);
  emit("loaded", book.value);
  await refreshCachedIndexes();
  const p = await readerApi.getProgress(props.bookId);
  // 详情页点某一章进来时带 index，优先于上次阅读进度。
  const want = props.startIndex;
  if (want !== undefined && Number.isFinite(want) && want >= 0 && Math.trunc(want) < chapters.value.length) {
    index.value = Math.trunc(want);
    return;
  }
  index.value = p.chapterIndex >= 0 ? p.chapterIndex : 0;
}

/** 重新拉取已缓存章节（缓存任务结束后目录标记要跟着变）。 */
async function refreshCachedIndexes() {
  if (!boundBookId.value) return;
  try {
    const list = await cacheApi.chapters(boundBookId.value);
    cachedIndexes.value = new Set(list.map((c) => c.index));
  } catch {
    // 目录标记属于锦上添花，取不到就当没有缓存，不打断阅读。
    cachedIndexes.value = new Set();
  }
}

/** 缓存菜单：本章 / 剩余 / 整本 / 去管理页。 */
async function onCacheCommand(command: string) {
  if (!book.value) return;
  if (!canCache.value) {
    ElMessage.warning("本地书无需缓存");
    return;
  }
  if (command === "manage") {
    router.push("/cache");
    return;
  }
  try {
    if (command === "chapter") {
      await cache.start(boundBookId.value, CacheScope.Chapters, [index.value]);
      ElMessage.success(`已开始缓存「${content.value?.title || "本章"}」`);
      return;
    }
    const scope =
      command === "all" ? CacheScope.All : CacheScope.Remaining;
    await cache.start(boundBookId.value, scope);
    ElMessage.success(command === "all" ? "已开始缓存整本" : "已开始缓存剩余章节");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/** 任务结束后刷新目录上的缓存标记。 */
watch(
  () => cacheJob.value?.state,
  async (state, prev) => {
    if (prev === "running" && state && state !== "running") {
      await refreshCachedIndexes();
    }
  },
);

/** 倒序只影响展示顺序，c.index 仍是真实章节号，跳转/高亮/缓存标记不受影响。 */
const displayChapters = computed(() =>
  tocReversed.value ? [...chapters.value].reverse() : chapters.value,
);

/** 切换排序后把当前章滚回可见区。 */
async function toggleTocOrder() {
  tocReversed.value = !tocReversed.value;
  await nextTick();
  stageRef.value
    ?.querySelector<HTMLElement>(".toc-item.active")
    ?.scrollIntoView({ block: "center" });
}

/** 底栏避让安卓手势条：Tab 栏已隐藏，安全区要自己补。 */
const footerStyle = computed(() =>
  platform.isMobile && platform.safeArea.bottom
    ? { paddingBottom: `calc(8px + ${platform.safeArea.bottom}px)` }
    : undefined,
);

/** 本地书源文件已被移动/删除：后端在 ListBooks/GetBook 时 stat 标注。 */
const fileMissing = computed(() => book.value?.fileMissing === true);

/** 载入某章。返回是否成功——朗读自动翻章要靠它判断能不能继续。 */
async function loadChapter(i: number): Promise<boolean> {
  // 文件已缺失时正文必然取不到：面板已在展示，别再弹 OS 原始报错。
  if (fileMissing.value) return false;
  // 换章后浮层里的词已经不在屏幕上了，留着只会误导。
  dict.close();
  loading.value = true;
  try {
    content.value = await bookData.getContent(boundBookId.value, i);
    index.value = i;
    // 换章后必须回到顶部，否则新章节会继承上一章的滚动位置。
    await nextTick();
    const sc = scroller();
    if (sc) sc.scrollTop = 0;
    // 进度条跟着归零；不足一屏的短章则显示 100%（整章都看得见）。
    syncChapterPct(sc);
    await persistProgress(chapterPct.value);
    return true;
  } catch (e) {
    ElMessage.error((e as Error).message);
    return false;
  } finally {
    loading.value = false;
  }
}

/** 移除源文件已丢失的本地书：只删书架记录与进度，不动磁盘上的任何东西。 */
async function removeMissingBook() {
  const name = book.value?.name ?? "这本书";
  try {
    await ElMessageBox.confirm(
      `将从书架移除《${name}》及其目录与阅读进度，源文件本身不会被删除。`,
      "移除书籍",
      { type: "warning", confirmButtonText: "移除", cancelButtonText: "取消" },
    );
  } catch {
    return; // 用户取消
  }
  try {
    await bookshelfApi.deleteBook(boundBookId.value);
    bookData.invalidateBook(boundBookId.value);
    await useBookshelfStore().loadBooks();
    ElMessage.success("已从书架移除");
    router.replace("/");
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/**
 * 用户手动换章（上一章/下一章/目录）。
 * 朗读中要跟着换到新章，否则会出现「页面在第 5 章、声音还在念第 3 章」。
 */
async function userLoadChapter(i: number) {
  const ok = await loadChapter(i);
  if (!ok || !readingThisBook.value) return;
  await tts.start(session, { chapter: i, segIndex: 0 });
}

/**
 * 从目录选章：先收起抽屉再换章。
 * 不收的话移动端 62% 宽的抽屉会一直挡着正文，用户得再点一次「目录」。
 */
async function pickChapter(i: number) {
  tocVisible.value = false;
  await userLoadChapter(i);
}

function prev() {
  if (loading.value) return;
  if (index.value > 0) void userLoadChapter(index.value - 1);
}
function next() {
  if (loading.value) return;
  if (content.value && content.value.nextIndex >= 0) {
    void userLoadChapter(content.value.nextIndex);
  }
}

// ---------------- 取词 ----------------

/** 判断一个字符是否属于「词」的字符集（字母、数字、连字符、撇号）。 */
const WORD_CHAR = /[\p{L}\p{N}'-]/u;
/** 汉字判定：中文按固定窗口取，不走「连续字符」扩展（会把整句连成一个词）。 */
const HAN_CHAR = /[\u3400-\u9fff]/;
/** 中文取词窗口：点一个字，交给后端在这个窗口里做最长匹配。 */
const ZH_WINDOW = 4;

/**
 * 取坐标处的词。
 *
 * 移动端取词模式用它：安卓 WebView 长按会拉起系统 ActionMenu（复制/全选/搜索），
 * 自己的浮层会和它抢位置、抢焦点，所以改成「点词」而不是「长按选中」。
 */
function wordAtPoint(x: number, y: number): { word: string; rect: DOMRect } | null {
  const doc = document as Document & {
    caretRangeFromPoint?: (x: number, y: number) => Range | null;
    caretPositionFromPoint?: (x: number, y: number) => { offsetNode: Node; offset: number } | null;
  };
  let range: Range | null = doc.caretRangeFromPoint?.(x, y) ?? null;
  if (!range && doc.caretPositionFromPoint) {
    const pos = doc.caretPositionFromPoint(x, y);
    if (pos) {
      range = document.createRange();
      range.setStart(pos.offsetNode, pos.offset);
      range.collapse(true);
    }
  }
  if (!range) return null;
  const node = range.startContainer;
  if (node.nodeType !== Node.TEXT_NODE) return null;
  const text = node.textContent ?? "";
  const offset = Math.min(range.startOffset, text.length);
  if (!text) return null;

  let start = offset;
  let end = offset;
  if (HAN_CHAR.test(text[offset] ?? "")) {
    end = Math.min(text.length, offset + ZH_WINDOW);
  } else {
    // 点到词尾右侧时 offset 落在下一个字符上，回退一格再扩展，
    // 否则会取到右边那个词，用户会觉得「点谁不算准」。
    if (start >= text.length || !WORD_CHAR.test(text[start])) {
      start = Math.max(0, start - 1);
      end = start;
    }
    while (start > 0 && WORD_CHAR.test(text[start - 1])) start--;
    while (end < text.length && WORD_CHAR.test(text[end])) end++;
  }
  const word = text.slice(start, end).trim();
  if (!word) return null;

  const r = document.createRange();
  r.setStart(node, start);
  r.setEnd(node, end);
  const rect = r.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return null;
  return { word, rect };
}

/** 选区是否落在正文里（目录、页眉里的选中不该触发查词）。 */
function selectionInContent(range: Range): boolean {
  const root = contentEl();
  if (!root) return false;
  const node = range.commonAncestorContainer;
  return root === node || root.contains(node);
}

/**
 * 鼠标选词结束（桌面端）。
 *
 * 用 mouseup 而不是 selectionchange：后者在拖选过程中每移动一像素都触发，
 * 会把词库打满；而且中途的选区还没有意义。
 */
function onStageMouseUp(e: MouseEvent) {
  if (!dict.enabled) return;
  if (!canRead.value) return;
  // 点在浮层自身上的抬起不算选词。
  if ((e.target as HTMLElement)?.closest?.(".dict-pop")) return;
  void checkSelection();
}

/**
 * 读取当前选区并弹浮层。
 *
 * 延迟一帧再读：Chrome 在 mouseup 的同一 tick 里选区可能还是旧的，
 * 点第二个词时很容易查到上一个词。
 */
async function checkSelection() {
  await nextTick();
  const sel = window.getSelection();
  const text = sel?.toString().trim() ?? "";
  if (!sel || sel.rangeCount === 0 || !text) return;
  const range = sel.getRangeAt(0);
  if (!selectionInContent(range)) return;
  const rect = range.getBoundingClientRect();
  if (rect.width === 0 && rect.height === 0) return;
  dict.openAt(text, {
    left: rect.left,
    top: rect.top,
    width: rect.width,
    height: rect.height,
  });
}

/** 移动端取词模式下点正文：取词、不翻页、不产生选区。 */
function pickWordAt(e: MouseEvent) {
  const hit = wordAtPoint(e.clientX, e.clientY);
  if (!hit) return;
  window.getSelection()?.removeAllRanges();
  dict.openAt(hit.word, {
    left: hit.rect.left,
    top: hit.rect.top,
    width: hit.rect.width,
    height: hit.rect.height,
  });
}

/** 切换取词模式（仅移动端提供入口）。 */
function togglePicking() {
  dict.setPicking(!dict.picking);
  if (dict.picking) ElMessage.info("取词模式：点正文里的词即可查词");
}

/**
 * 阅读区点击翻页：左 1/3 上一章、右 1/3 下一章。
 * 中间 1/3 不响应，留给选词和滚轮，避免误翻页。
 *
 * 取词相关的两件事必须排在翻页**之前**：
 *   - 取词模式下点正文只取词（否则点左三分之一会直接翻章）；
 *   - 浮层开着时点正文先关浮层（否则关掉浮层的那一下会顺手翻页）。
 */
function onStageClick(e: MouseEvent) {
  const el = stageRef.value;
  if (!el) return;

  const target = e.target as HTMLElement;
  // 目录、链接、表单控件等交互元素不参与翻页。
  if (target.closest("a, button, input, textarea, select, .toc")) return;

  // 取词模式：只取词，不翻页、不切换栏位。
  if (dict.picking) {
    if (target.closest(".content")) pickWordAt(e);
    return;
  }
  // 浮层开着：这一下点击用于关闭它，不叠加翻页。
  if (dict.visible) {
    dict.close();
    return;
  }
  // 有选中文字时说明用户在选词，不要抢这一下点击。
  if (window.getSelection()?.toString()) return;

  // 朗读中：点正文 = 从这一段开始读（优先于左右三分之一的翻页）。
  if (readingThisBook.value && target.closest(".content")) {
    const idx = tts.findSegmentIndex(target);
    if (idx >= 0) {
      tts.jumpTo(idx);
      return;
    }
  }

  const rect = el.getBoundingClientRect();
  if (rect.width === 0) return;
  const ratio = (e.clientX - rect.left) / rect.width;
  if (ratio < 1 / 3) prev();
  else if (ratio > 2 / 3) next();
  // 中间 1/3 切换栏位：移动端一直如此；桌面端只在全屏时响应，
  // 非全屏下中间留给选词（那才是桌面上的高频操作）。
  else if (layout.immersive) chromeVisible.value = !chromeVisible.value;
}

/** 左右方向键翻章；输入框或带修饰键的按键不接管。 */
function onKeydown(e: KeyboardEvent) {
  // 分屏时只有活动栏响应，否则两栏会同时翻章。
  if (!props.active) return;
  if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) {
    return;
  }
  const target = e.target as HTMLElement | null;
  if (
    target &&
    (/^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) || target.isContentEditable)
  ) {
    return;
  }
  if (e.key === "Escape") {
    // Esc 逐层退：浮层 > 取词 > 收起栏位 > 退出全屏。
    // 顺序不能反：浮层是临时遮挡物，最先关；全屏是视图状态，最后退。
    if (dict.visible) {
      dict.close();
      e.preventDefault();
    } else if (dict.picking) {
      dict.setPicking(false);
    } else if (layout.fullscreen) {
      e.preventDefault();
      // 栏位还收着就先展开（用户多半想找回顶栏），已经展开才真的退全屏。
      if (!chromeVisible.value) chromeVisible.value = true;
      else void layout.exit();
    } else {
      // 本栏没得退了，交回外壳（分屏态下是「关右栏」）。
      emit("escape");
    }
    return;
  }
  if (e.key === "F11") {
    // 全屏快捷键。安卓端没有窗口层，layout.toggle 只影响栏位，
    // 但那边压根收不到 F11，所以不需要额外判平台。
    e.preventDefault();
    void toggleFullscreen();
    return;
  }
  if (e.key === "ArrowLeft") {
    e.preventDefault();
    prev();
  } else if (e.key === "ArrowRight") {
    e.preventDefault();
    next();
  }
}

/** 真正落库。单独拆出来是因为「变成非活动栏时的补写」要能绕过 active 判定。 */
async function writeProgress(scrollPercent: number) {
  const title = content.value?.title ?? chapters.value[index.value]?.title ?? "";
  await readerApi.saveProgress(boundBookId.value, index.value, title, 0, scrollPercent);
  // 进度变了，详情页展示的进度字段失效，下次进详情重新拉。
  bookData.invalidateBook(boundBookId.value);
}

/** 保存进度；scrollPercent 由滚动位置计算。 */
async function persistProgress(scrollPercent: number) {
  // 分屏时只有活动栏写进度：两栏可能开着同一本书，都写就是互相覆盖。
  // 变成非活动栏时的最后一笔由下方 watch(active) 直接调 writeProgress 补上。
  if (!props.active) return;
  await writeProgress(scrollPercent);
}

/**
 * 拖进度条：把百分比换算成滚动位置。
 *
 * 只滚不落盘——拖动过程中每个 pointermove 都写一次进度毫无意义，
 * 而且 saveProgress 是异步的，一秒几十次会把请求堆起来。落盘交给抬手。
 */
function seekChapter(percent: number) {
  const sc = scroller();
  if (!sc) return;
  sc.scrollTop = scrollTopForPercent(percent, sc.scrollHeight, sc.clientHeight);
  // 回读而不是直接用入参：浏览器会把 scrollTop 夹到合法范围（小数也会取整），
  // 拿实际值回填，进度条才不会在松手时跳一下。
  syncChapterPct(sc);
}

/** 抬起手指/鼠标：补最后一帧滚动并落盘。 */
function seekChapterEnd(percent: number) {
  seekChapter(percent);
  // 朗读期间进度由朗读器按「段」推进并落盘，这里让位，避免两处互相覆盖。
  if (readingThisBook.value) return;
  void persistProgress(chapterPct.value);
}

/** 滚动时记录百分比（节流由浏览器 rAF 自然合并）。 */
function onScroll(e: Event) {
  // 用户滚的是这一栏：先抢占 active，否则非活动栏滚了也不写进度。
  if (!props.active) emit("activate");
  // 一滚就关浮层：它固定在选区原来的位置，正文一动就会飘到别处，
  // 跟随滚动比关掉更费心且总是慢半拍。
  if (dict.visible) dict.close();
  const el = e.target as HTMLElement;
  // 进度条要跟着走，包括朗读时自动滚动的位置，所以排在「朗读让位」判定**之前**。
  syncChapterPct(el);
  // 朗读期间进度由朗读器按「段」推进并落盘，这里让位，避免两处互相覆盖。
  if (readingThisBook.value) return;
  const max = el.scrollHeight - el.clientHeight;
  if (max <= 0) return;
  persistProgress(chapterPct.value);
}

// ---------------- 朗读 ----------------

/** 正文容器与标题元素（朗读切段的输入）。 */
function contentEl(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".content") ?? null;
}
function titleEl(): HTMLElement | null {
  return stageRef.value?.querySelector<HTMLElement>(".text h1") ?? null;
}

/**
 * 朗读会话：store 只跟这个接口打交道，DOM 细节全留在窗格里。
 * M2 的 PDF 换成「页级」实现后，store 一行都不用改。
 */
const session: TtsSession = {
  get bookId() {
    return boundBookId.value;
  },
  get bookName() {
    return book.value?.name ?? "";
  },
  chapterTitle: (ch) => chapters.value[ch]?.title ?? "",
  extract: async (ch) => {
    if (ch !== index.value) {
      const ok = await loadChapter(ch);
      if (!ok) return [];
    }
    await nextTick();
    const root = contentEl();
    const title = content.value?.title ?? chapters.value[ch]?.title ?? "";
    // 窗格还挂着：直接在活 DOM 上切段，段落能带 el，高亮才生效。
    if (root) return domSegment(root, { chapter: ch, title: titleEl() });
    // 已经离开阅读器（组件卸载）：用同一份 HTML 离线切段，接着往下读。
    return segmentHTML(content.value?.html ?? "", { chapter: ch, title });
  },
  advance: async (i) => {
    // 后端给的 nextIndex 最权威（有的书章节不连续），退回 +1。
    const ni = content.value?.nextIndex ?? -1;
    const next = ni >= 0 ? ni : i + 1 < chapters.value.length ? i + 1 : -1;
    if (next < 0) return null;
    const ok = await loadChapter(next);
    return ok ? next : null;
  },
  save: (ch, _segIndex, ratio) => {
    const title = chapters.value[ch]?.title ?? "";
    void readerApi
      .saveProgress(
        boundBookId.value,
        ch,
        title,
        0,
        Math.round(ratio * 100),
      )
      .then(() => bookData.invalidateBook(boundBookId.value));
  },
};

/** 视口顶端的第一段：点「朗读」时从这里开始，而不是永远从章首。 */
function visibleSegmentIndex(): number {
  const root = contentEl();
  const sc = scroller();
  if (!root || !sc) return 0;
  const list = domSegment(root, { chapter: index.value, title: titleEl() });
  if (!list.length) return 0;
  const top = sc.getBoundingClientRect().top;
  for (let i = 0; i < list.length; i++) {
    const r = (list[i].el as HTMLElement).getBoundingClientRect();
    if (r.bottom > top + 4) return i;
  }
  return list.length - 1;
}

async function toggleRead() {
  if (!canRead.value) {
    ElMessage.warning(isComic.value ? "漫画没有文本，无法朗读" : "该格式暂不支持朗读");
    return;
  }
  if (readingThisBook.value) {
    tts.toggle();
    return;
  }
  await tts.start(session, {
    chapter: index.value,
    segIndex: visibleSegmentIndex(),
  });
}

/** 当前高亮元素（同一元素可能被多个段落共享，只需记住一个）。 */
let activeEl: HTMLElement | null = null;

function clearHighlight() {
  if (!activeEl) return;
  activeEl.classList.remove("tts-active");
  activeEl = null;
}

watch(
  () => tts.currentSegment,
  (seg) => {
    clearHighlight();
    if (!seg || tts.bookId !== boundBookId.value) return;
    const el = seg.el as HTMLElement | undefined;
    if (!el || !el.isConnected) return;
    const stage = stageRef.value;
    if (!stage || !stage.contains(el)) return;
    el.classList.add("tts-active");
    activeEl = el;
    // 只在段落跑出视口时才滚动，避免每段都把页面拽一下。
    const box = stage.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    if (r.top < box.top + 40 || r.bottom > box.bottom - 40) {
      // 用即时滚动而不是 smooth：连续朗读时段间只有几秒，平滑滚动会一直排不上队，
      // 观感是"高亮在跑、页面在追"，而且滚动过程中用户点击会点歪。
      el.scrollIntoView({ block: "center" });
    }
  },
);

/** 变成非活动栏：把最后那笔进度补上，之后就不再写（等下次被激活）。 */
watch(
  () => props.active,
  (on, was) => {
    // 直接调 writeProgress：此刻 props.active 已经是 false，
    // 走 persistProgress 会被 active 判定挡掉，这一笔就永远补不上。
    if (was && !on && book.value) void writeProgress(chapterPct.value);
  },
);

watch(
  () => props.bookId,
  async () => {
    if (!props.bookId) return;
    clearHighlight();
    await loadMeta();
    await loadChapter(index.value);
    tts.attach(session);
  },
);

onMounted(async () => {
  window.addEventListener("keydown", onKeydown);
  // 窗口尺寸变了，同一章节的可滚动范围就变了，进度百分比要跟着重算。
  window.addEventListener("resize", queueSyncChapterPct);
  if (!props.bookId) return;
  await loadMeta();
  await loadChapter(index.value);
  // 绑定在正文渲染之后：store 若仍在读这本书，会重新切段以恢复高亮锚点。
  tts.attach(session);
});

onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
  window.removeEventListener("resize", queueSyncChapterPct);
  clearHighlight();
  // 解绑但不停播：文本类离开阅读器后可以继续听（这是需求，不是遗漏）。
  tts.detach(boundBookId.value);
});

/** 供外壳调用：全屏切换会改变可滚动范围，按百分比还原位置要在窗格里做。 */
defineExpose({ prev, next, toggleFullscreen, chapterPct, book });
</script>

<template>
  <div class="pane" v-loading="loading" @pointerdown.capture="emit('activate')">
    <header v-show="chromeShown" class="bar">
      <!-- 分屏态：本栏左上角是关闭按钮（单栏的返回键在外壳里，这里不出现） -->
      <el-button v-if="compact" link data-reader="close-pane" @click="emit('close')">
        ✕
      </el-button>
      <el-button v-else link @click="emit('back')">← 返回</el-button>
      <span class="title">{{ book?.name }}</span>
      <span class="chapter">{{ content?.title }}</span>
      <div class="spacer" />
      <el-tooltip v-if="!compact" content="复制书籍地址" placement="bottom">
        <button class="icon-btn" :disabled="!book" @click="copyBookURL">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <rect x="9" y="9" width="11" height="11" rx="2" />
            <path d="M5 15V6a2 2 0 0 1 2-2h9" />
          </svg>
        </button>
      </el-tooltip>
      <el-button link class="read-btn" :disabled="!canRead" @click="toggleRead">
        {{ readLabel }}
      </el-button>
      <el-dropdown v-if="!compact" trigger="click" @command="onCacheCommand">
        <el-button link class="cache-btn" :disabled="!canCache">
          {{ cacheLabel }}
        </el-button>
        <template #dropdown>
          <el-dropdown-menu>
            <el-dropdown-item command="chapter">缓存本章</el-dropdown-item>
            <el-dropdown-item command="remaining">缓存剩余章节</el-dropdown-item>
            <el-dropdown-item command="all">缓存整本</el-dropdown-item>
            <el-dropdown-item command="manage" divided>管理缓存…</el-dropdown-item>
          </el-dropdown-menu>
        </template>
      </el-dropdown>
      <el-button v-if="!compact" link data-ai="ask-ai" @click="askOpen = true">问 AI</el-button>
      <!--
        全屏阅读只在桌面端出现：安卓那边 WebView 本来就铺满屏幕，
        隐藏顶栏底栏（点正文中间）就是它的全屏，不需要窗口层。
      -->
      <!--
        分屏入口只在单栏桌面端出现：分屏后每栏是精简头，再点一次没有意义；
        安卓端屏幕宽度不够两栏并排（设计上就不支持）。
      -->
      <el-button
        v-if="!compact && !platform.isMobile"
        link
        data-reader="split"
        @click="emit('split')"
      >
        分屏
      </el-button>
      <el-button
        v-if="!platform.isMobile"
        link
        data-reader="fullscreen"
        @click="toggleFullscreen"
      >
        {{ layout.fullscreen ? "退出全屏" : "全屏" }}
      </el-button>
      <el-button link @click="tocVisible = !tocVisible">目录</el-button>
    </header>

    <div class="stage" ref="stageRef" @click="onStageClick" @mouseup="onStageMouseUp">
      <!-- 目录抽屉 -->
      <aside v-show="tocVisible" class="toc">
        <div class="toc-head">
          <span>目录</span>
          <button class="toc-order" @click="toggleTocOrder">
            {{ tocReversed ? "正序 ↑" : "倒序 ↓" }}
          </button>
        </div>
        <div
          v-for="c in displayChapters"
          :key="c.index"
          class="toc-item"
          :class="{ active: c.index === index }"
          @click="pickChapter(c.index)"
        >
          <span class="toc-title">{{ c.title }}</span>
          <span
            v-if="cachedIndexes.has(c.index)"
            class="toc-cached"
            title="已缓存，可离线阅读"
            >●</span
          >
        </div>
      </aside>

      <!-- 本地书源文件缺失：明确的状态页，代替每次进来的 OS 原始报错 -->
      <div v-if="fileMissing" class="file-missing">
        <p class="fm-title">找不到书籍文件</p>
        <p class="fm-desc">《{{ book?.name }}》的源文件可能已被移动、重命名或删除。</p>
        <p class="fm-path" :title="book?.bookUrl">{{ book?.bookUrl }}</p>
        <div class="fm-actions">
          <el-button @click="emit('back')">返回</el-button>
          <el-button type="danger" plain @click="removeMissingBook">从书架移除</el-button>
        </div>
      </div>

      <!-- PDF：交给 WebView 内置 PDF 能力 -->
      <iframe v-else-if="isPdf" class="pdf" :src="pdfURL" />

      <!-- 漫画：图片流 -->
      <div v-else-if="isComic" class="comic" @scroll="onScroll">
        <img
          v-for="(src, i) in content?.images || []"
          :key="i"
          :src="comicImageURL(src, book?.origin)"
          loading="lazy"
          @load="queueSyncChapterPct"
        />
      </div>

      <!-- 文本类：正文 HTML -->
      <article
        v-else
        class="text"
        :style="{ fontSize: style.fontSize + 'px', lineHeight: style.lineHeight }"
        @scroll="onScroll"
        @load.capture="queueSyncChapterPct"
      >
        <h1>{{ content?.title }}</h1>
        <!--
          正文来自书源或本地文件，属受控内容。
          后续可接入净化规则（替换/去广告）后再渲染，进一步降低风险。
        -->
        <div class="content" v-html="displayHTML" />
      </article>
    </div>

    <!-- 本章进度：按住/拖动直接滚到对应位置。PDF 的滚动归 iframe 自己管，不参与 -->
    <ChapterProgress
      v-show="chromeShown"
      :percent="chapterPct"
      :disabled="isPdf || fileMissing || !chapterScrollable"
      @seek="seekChapter"
      @seek-end="seekChapterEnd"
    />

    <footer v-show="chromeShown" class="nav" :style="footerStyle">
      <el-button :disabled="index <= 0" @click="prev">上一章</el-button>
      <span class="pos">
        {{ index + 1 }} / {{ content?.totalChapters || chapters.length }}
      </span>
      <el-button
        :disabled="!content || content.nextIndex < 0"
        @click="next"
      >
        下一章
      </el-button>
      <div class="spacer" />
      <!-- 移动端取词入口：安卓 WebView 长按会拉起系统菜单，只能改成「点词」 -->
      <el-button
        v-if="platform.isMobile"
        link
        :type="dict.picking ? 'primary' : undefined"
        data-dict="pick-toggle"
        :disabled="!canRead"
        @click="togglePicking"
      >
        词典
      </el-button>
      <span class="setting">字号</span>
      <el-slider
        v-model="style.fontSize"
        :min="14"
        :max="28"
        class="r-fit"
        style="--r-fit-w: 120px"
      />
    </footer>

    <!-- 问 AI 抽屉：读到一半有疑问时不必离开正文 -->
    <AskAIDrawer
      v-model="askOpen"
      :book-id="boundBookId"
      :book-name="book?.name || ''"
    />
  </div>
</template>

<style scoped>
/*
 * 窗格本体：外壳负责「留出侧栏/分屏」的位置，窗格只负责自己那一列的
 * 顶栏-正文-进度条-底栏四段纵向排布。
 */
.pane {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
  min-height: 0;
  overflow: hidden;
}
.bar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  background: #fff;
  border-bottom: 1px solid #e5e7eb;
}
.title {
  font-weight: 600;
  /* 窄屏下书名/章节名必须能收缩加省略号：否则逐字折行会把顶栏撑成竖排大块。 */
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.chapter {
  font-size: 12px;
  color: #6b7280;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.spacer {
  flex: 1;
  min-width: 0;
}
.icon-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
  width: 28px;
  height: 28px;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: transparent;
  cursor: pointer;
}
.icon-btn:hover:not(:disabled) {
  background: rgba(0, 0, 0, 0.06);
}
.icon-btn:disabled {
  cursor: default;
  opacity: 0.4;
}
.icon-btn svg {
  width: 17px;
  height: 17px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.7);
  stroke-width: 1.8;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.stage {
  flex: 1;
  display: flex;
  min-height: 0;
  min-width: 0;
}
/* 本地书源文件缺失的状态页 */
.file-missing {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: var(--r-gap);
  padding: var(--r-pad);
  min-width: 0;
  max-width: 100%;
  text-align: center;
}
.file-missing .fm-title {
  font-size: 18px;
  font-weight: 600;
  color: #303133;
}
.file-missing .fm-desc {
  color: #606266;
}
.file-missing .fm-path {
  max-width: 80%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-size: 12px;
  color: #909399;
  font-family: monospace;
}
.file-missing .fm-actions {
  margin-top: 8px;
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
}
.toc {
  width: min(100%, 320px);
  max-width: 100%;
  flex: none;
  overflow: auto;
  background: #fff;
  border-right: 1px solid #e5e7eb;
  padding: var(--r-pad-sm) 0;
}
.toc-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  padding: var(--r-pad-sm) var(--r-pad);
  font-size: 13px;
  font-weight: 600;
  color: #374151;
  border-bottom: 1px solid #f3f4f6;
}
.toc-order {
  border: none;
  background: transparent;
  padding: 2px 4px;
  font-size: 12px;
  font-weight: 400;
  color: #4f46e5;
  cursor: pointer;
}
.toc-order:hover {
  text-decoration: underline;
}
.toc-item {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  min-width: 0;
  padding: var(--r-pad-sm) var(--r-pad);
  font-size: 13px;
  cursor: pointer;
  color: #374151;
}
.toc-title {
  flex: 1;
  min-width: 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.toc-cached {
  flex: none;
  font-size: 8px;
  color: #16a34a;
}
.toc-item:hover {
  background: #f3f4f6;
}
.toc-item.active {
  color: #4338ca;
  font-weight: 600;
  background: #eef2ff;
}
.pdf {
  flex: 1;
  min-width: 0;
  max-width: 100%;
  border: none;
}
.comic {
  flex: 1;
  min-width: 0;
  max-width: 100%;
  overflow: auto;
  background: #1f2328;
}
.comic img {
  display: block;
  width: 100%;
}
.text {
  flex: 1;
  min-width: 0;
  max-width: 100%;
  overflow: auto;
  padding: var(--r-pad) var(--r-pad) 64px;
  background: #fffdf7;
}
.text h1 {
  font-size: 1.4em;
  margin: 0 0 20px;
}
.content {
  max-width: min(100%, 760px);
  margin: 0 auto;
}
.content :deep(p) {
  margin: 0 0 1em;
  text-indent: 2em;
}
.content :deep(img) {
  max-width: 100%;
}
/*
 * 正在朗读的段落。用 box-decoration-break 让跨行的底色连成一片，
 * 否则多行段落会显示成一截一截的。
 */
.content :deep(.tts-active),
.content :deep(.tts-seg.tts-active) {
  background: rgba(99, 102, 241, 0.16);
  border-radius: 3px;
  box-decoration-break: clone;
  -webkit-box-decoration-break: clone;
  transition: background 0.2s ease;
}
.nav {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: var(--r-pad-sm) var(--r-pad);
  min-width: 0;
  background: #fff;
  border-top: 1px solid #e5e7eb;
}
.pos {
  font-size: 13px;
  color: #6b7280;
}
.setting {
  font-size: 13px;
  color: #6b7280;
}

/* AI 引用跳转的高亮：淡黄底而非高饱和色，避免打断阅读节奏 */
:deep(mark.ai-hit) {
  background: #fff3c4;
  color: inherit;
  padding: 0 1px;
  border-radius: 2px;
}

/* 移动端：顶栏去掉章节名（正文里已有 h1），压缩内边距，抽屉加宽好点按 */
@media (max-width: 640px) {
  /* 顶栏是沉浸阅读的一部分，窄屏**不能换行**：
     换行会把 56px 的标题栏撑到 ~100px，直接吃掉正文可视高度，
     也让 s13 的「顶栏 <= 60px」验收失败。放不下的按钮改为横向滚动。 */
  .bar {
    flex-wrap: nowrap;
    overflow-x: auto;
    overflow-y: hidden;
    height: 56px;
    gap: var(--r-gap-sm);
    padding: var(--r-pad-sm);
    scrollbar-width: none;
  }
  .bar::-webkit-scrollbar {
    display: none;
  }
  .bar > * {
    flex: none;
  }
  .bar .title {
    flex: 0 1 auto;
  }
  .chapter {
    display: none;
  }
  /* 复制书籍地址在手机上几乎不用，让位给书名 */
  .icon-btn {
    display: none;
  }
  .nav {
    flex-wrap: nowrap;
    gap: var(--r-gap-sm);
    padding: var(--r-pad-sm);
  }
  .toc {
    width: min(100%, 320px);
  }
}
</style>
