<script setup lang="ts">
/**
 * 发现页：按书源提供的分类/榜单翻书，不需要关键词。
 *
 * 布局按 Legado 原生的三份布局文件对齐：
 *  - fragment_explore.xml：标题栏（标题 + 搜索框）下面直接是列表。
 *  - item_find_book.xml：书源是「全宽手风琴行」——整行左右 16dp、上 12dp，
 *    行内是一条 6dp 圆角、10dp/6dp 内边距的灰条（transparent10）；右侧
 *    20dp 箭头，展开时转成向下并显示转圈；展开体左右再缩进 8dp，上边距
 *    8dp、内边距 3dp，里面铺圆角 16dp 的胶囊。
 *  - activity_explore_show.xml + item_search.xml：点胶囊是整页跳转到结果页，
 *    行 = 80×110 封面 + 16sp 书名 + 12sp 作者/分类/最新章节/简介，
 *    行间只有一条细分割线，滚动到底自动加载，底部只有状态提示。
 *
 * 两处桌面适配（不改变视觉结构）：
 *  1. 列表限制最大宽度并居中，否则宽屏下书源条会拉成整屏长条。
 *  2. 原生靠长按弹菜单，这里把分组筛选放到标题栏右侧。
 */
import { computed, nextTick, onActivated, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { ElMessage } from "element-plus";

import { sourceApi } from "@/api/source";
import { useSourcesStore } from "@/stores/sources";
import { smartBack } from "@/utils/nav";
import { coverURL } from "@/utils/media";
import type { ExploreKindView, ExploreSourceBrief, SearchResultView } from "@/types";

/** 单个书源的分类加载状态。 */
interface KindsState {
  loading: boolean;
  error: string;
  list: ExploreKindView[];
}

/** 正在浏览的分类（为空表示停留在书源列表）。 */
interface ActiveKind {
  sourceId: number;
  sourceName: string;
  kind: ExploreKindView;
}

const router = useRouter();
const route = useRoute();
const sourceStore = useSourcesStore();

const sources = ref<ExploreSourceBrief[]>([]);
const booting = ref(true);
const filter = ref("");
const group = ref("");
const expanded = ref<number | null>(null);
const kindsState = ref<Record<number, KindsState>>({});

const active = ref<ActiveKind | null>(null);
const books = ref<SearchResultView[]>([]);
const page = ref(1);
const loadingBooks = ref(false);
const loadedOnce = ref(false);
const noMore = ref(false);
/** 自动续加载次数：一页装不满一屏时补下一页，同时防止规则异常时空转。 */
const autoFills = ref(0);
const bookScroll = ref<HTMLElement | null>(null);
const listScroll = ref<HTMLElement | null>(null);
/** 进入分类前记住书源列表的滚动位置，返回时还原（原生是独立 Activity，状态天然保留）。 */
const savedScroll = ref(0);
const itemRefs = new Map<number, HTMLElement>();
/** 加载失败的封面地址：站点常返回 403 或死链，失败后不显示破图与 alt 文字。 */
const brokenCover = ref<Record<string, boolean>>({});

function markCoverBroken(url: string) {
  brokenCover.value = { ...brokenCover.value, [url]: true };
}

function setItemRef(id: number, el: unknown) {
  if (el instanceof HTMLElement) itemRefs.set(id, el);
  else itemRefs.delete(id);
}

const groups = computed(() => {
  const set = new Set<string>();
  for (const s of sources.value) {
    if (s.group) set.add(s.group);
  }
  return [...set];
});

const visibleSources = computed(() => {
  const kw = filter.value.trim().toLowerCase();
  return sources.value.filter((s) => {
    if (group.value && s.group !== group.value) return false;
    if (kw && !s.name.toLowerCase().includes(kw)) return false;
    return true;
  });
});

/** 分类地址里带分页变量才可能翻页，其余源只有一页。 */
const paged = computed(() => active.value?.kind.paged ?? false);

function stateOf(id: number): KindsState | undefined {
  return kindsState.value[id];
}

/** 取某书源的分类列表；未加载时返回空数组，避免 v-for 遇到 undefined。 */
function kindsOf(id: number): ExploreKindView[] {
  return kindsState.value[id]?.list ?? [];
}

/**
 * 并发重拉时只认最后一次的结果：书源页批量操作会连着改几次 store，
 * 旧请求后到会把列表打回中间状态。
 */
let loadSeq = 0;

/** 内容没变就不动展开态 / 分类缓存 / 滚动位置，保住 keep-alive 的体验。 */
function sameSources(a: ExploreSourceBrief[], b: ExploreSourceBrief[]): boolean {
  if (a.length !== b.length) return false;
  return a.every(
    (s, i) =>
      s.id === b[i].id &&
      s.name === b[i].name &&
      (s.group ?? "") === (b[i].group ?? ""),
  );
}

async function loadSources() {
  const seq = ++loadSeq;
  booting.value = true;
  try {
    const list = (await sourceApi.listExploreSources()) ?? [];
    if (seq !== loadSeq) return; // 已有更新的重拉，丢弃这次结果
    if (sameSources(sources.value, list)) return;
    sources.value = list;
    // 重新拉列表通常是因为改了书源规则，缓存的分类可能已过期。
    kindsState.value = {};
    expanded.value = null;
    // 选中的分组若已被改名/删掉，清掉筛选，否则列表会一直空着。
    if (group.value && !list.some((s) => (s.group ?? "") === group.value)) {
      group.value = "";
    }
  } catch (e) {
    if (seq !== loadSeq) return;
    ElMessage.error((e as Error).message);
  } finally {
    if (seq === loadSeq) booting.value = false;
  }
}

async function reload() {
  await loadSources();
  // 有展开中的源时顺带刷新它的分类，避免用户以为「刷新没反应」。
  if (expanded.value !== null) {
    const id = expanded.value;
    expanded.value = null;
    await toggle(id);
  }
}

/**
 * 书源变更后同步发现页。
 *
 * 这个组件在 App.vue 里被 keep-alive 缓存，setup 只在首次挂载跑一次；
 * 书源页的增删改只就地更新 sources store，以前没有任何通知能到这里，
 * 于是「书源页加了源、发现页要整页刷新才看得见」。两条触发路径：
 *  - revision：所有走 store 的变更立刻重拉，用户还在别的页面时数据也是新的；
 *  - onActivated：切回发现页再兜一次，覆盖不经过前端 store 的写入
 *    （订阅同步、外部直接调后端 API 等）。
 * 两次重拉撞在一起时 loadSeq 会丢弃过期响应；sameSources 保证内容没变
 * 时不会收起用户展开的分类。
 */
watch(
  () => sourceStore.revision,
  () => {
    void loadSources();
  },
);
// keep-alive 组件首次挂载时 onActivated 也会跑一次，与下面的顶层加载并发；
// loadSeq 丢弃过期响应，sameSources 保证内容没变时不重置展开状态。
// 顶层加载单独保留：即便将来把本页移出 keep-alive，首屏也照样有数据。
onActivated(() => {
  void loadSources();
});

loadSources();

async function loadKinds(id: number) {
  const cur = kindsState.value[id];
  if (cur && (cur.loading || cur.list.length > 0)) return;
  kindsState.value[id] = { loading: true, error: "", list: [] };
  try {
    const list = (await sourceApi.exploreKinds(id)) ?? [];
    kindsState.value[id] = { loading: false, error: "", list };
  } catch (e) {
    kindsState.value[id] = { loading: false, error: (e as Error).message, list: [] };
  }
}

/**
 * 把展开的那条滚到列表顶部。
 * 原版展开后调用 scrollToPositionWithOffset(position, 0)，这里按矩形差换算。
 */
function scrollSourceToTop(id: number) {
  const el = itemRefs.get(id);
  const box = listScroll.value;
  if (!el || !box) return;
  const delta = el.getBoundingClientRect().top - box.getBoundingClientRect().top;
  // 已经在顶部就别再滚，避免点击上方书源时整页抖动。
  if (delta <= 1) return;
  box.scrollTo({ top: box.scrollTop + delta, behavior: "smooth" });
}

/** 点书源头部：折叠/展开（同时只允许展开一个，与原版一致），展开时才解析分类。 */
async function toggle(id: number) {
  if (expanded.value === id) {
    expanded.value = null;
    return;
  }
  expanded.value = id;
  await nextTick();
  scrollSourceToTop(id);
  await loadKinds(id);
}

/**
 * 分类书单在 URL 上的深度标记（sid=书源 id，k=该源分类列表里的下标）。
 *
 * 书单是「页面内的二级页」，但必须让 vue-router 也记一条历史：安卓返回键
 * 是 WebView.goBack()、桌面 Alt+← 同样是 popstate，它们只认路由记账，
 * 不认组件里的 active。以前 openKind 只改组件状态，按返回就直接退到上一个
 * tab；现在这条 query 记录就是书单页的历史入口。
 * 书单数据仍留在组件里（keep-alive 保留 books / 滚动位置 / 展开的分类），
 * query 只用来驱动收起，不承载数据。
 */
const kindMark = computed(() => {
  const k = route.query.k;
  return typeof k === "string" && k !== "" ? k : null;
});

async function openKind(sourceId: number, kind: ExploreKindView) {
  const src = sources.value.find((s) => s.id === sourceId);
  if (!src) return;
  // 原版把解析失败也做成一个分类（标题以 ERROR 开头），点击时弹详情。
  if (kind.title.startsWith("ERROR")) {
    ElMessage.error(kind.url || "该分类解析失败，请检查书源规则");
    return;
  }
  if (!kind.url) return;

  savedScroll.value = listScroll.value?.scrollTop ?? 0;
  active.value = { sourceId, sourceName: src.name, kind };
  books.value = [];
  page.value = 1;
  noMore.value = false;
  loadedOnce.value = false;
  autoFills.value = 0;
  // 先压历史再取书：用户点完立刻按返回，那条记录也必须已经存在。
  // 用下标而不是分类 url，避免把含 {{page}}、& 的规则地址塞进 URL。
  const idx = kindsOf(sourceId).findIndex(
    (x) => x.title === kind.title && x.url === kind.url,
  );
  if (idx >= 0) {
    void router.push({
      name: "explore",
      query: { sid: String(sourceId), k: String(idx) },
    });
  }
  await fetchPage(1, false);
  await nextTick();
  bookScroll.value?.scrollTo({ top: 0 });
}

/** 收起书单：只动组件状态，展开的分类与列表滚动位置都留着。 */
async function clearActive() {
  active.value = null;
  books.value = [];
  await nextTick();
  if (listScroll.value) listScroll.value.scrollTop = savedScroll.value;
}

/** 页面内「返回发现」按钮：和系统返回键走同一条路，避免两条逻辑分叉。 */
function backToSources() {
  if (!kindMark.value) {
    // 没压过历史（分类下标意外缺失时不 push），退回组件内收起即可。
    void clearActive();
    return;
  }
  smartBack(router, "/explore", { mustMatch: "/explore" });
}

/**
 * 系统返回键 / Alt+← / 从别的 tab 回到无标记的 /explore 时，vue-router
 * 更新 query.k → 这里收起书单；从书籍详情返回时 query.k 不变，书单原样保留。
 * 前进键或带 query 的深链会出现「URL 有标记、组件状态已丢」，此时校正回
 * 一级列表，不假装还在看某个分类（也顺手清掉跳走再回来的残留书单）。
 */
watch(kindMark, (mark) => {
  // 本页在 keep-alive 里，切到 /book/:id 等别的路由时组件并不会卸载，
  // 全局 route.query 的变化照样会触发这个 watch。那不是「从书单返回」，
  // 若在这里清状态 / 校正 URL，从详情页返回时书单就没了、URL 还会被
  // replace 成无标记的 /explore。只在当前路由确实属于发现页时处理。
  if (route.name !== "explore") return;
  if (!mark) {
    if (active.value) void clearActive();
  } else if (!active.value) {
    void router.replace({ name: "explore" });
  }
});

async function fetchPage(target: number, append: boolean) {
  const cur = active.value;
  if (!cur || loadingBooks.value) return;
  loadingBooks.value = true;
  try {
    const list =
      (await sourceApi.explore(cur.sourceId, cur.kind.url, target)) ?? [];
    if (append) {
      // 站点翻页常出现重复条目，按地址去重后再追加。
      const seen = new Set(books.value.map((b) => b.bookUrl));
      books.value = books.value.concat(list.filter((b) => !seen.has(b.bookUrl)));
    } else {
      books.value = list;
    }
    page.value = target;
    loadedOnce.value = true;
    // 空页或该源根本不支持分页，都意味着没有下一页了。
    noMore.value = list.length === 0 || !cur.kind.paged;
  } catch (e) {
    ElMessage.error((e as Error).message);
    if (!append) books.value = [];
    loadedOnce.value = true;
    noMore.value = true;
  } finally {
    loadingBooks.value = false;
  }
  await nextTick();
  fillViewport();
}

/**
 * 一页书籍不足一屏时，滚动条根本不出现，触底加载永远触发不了。
 *
 * 桌面窗口比手机高得多，这种情况很常见（站点每页只给 8~10 本），
 * 因此内容没铺满时自动续加载下一页，最多连补 4 页。
 */
function fillViewport() {
  const el = bookScroll.value;
  if (!el || loadingBooks.value || noMore.value || !active.value) return;
  if (autoFills.value >= 4) return;
  if (el.scrollHeight > el.clientHeight + 40) return;
  autoFills.value++;
  fetchPage(page.value + 1, true);
}

/** 滚动到底自动加载下一页（原版 onScrolled 判 canScrollVertically(1)）。 */
function onBookScroll(e: Event) {
  const el = e.target as HTMLElement;
  if (!active.value || loadingBooks.value || noMore.value) return;
  if (el.scrollTop + el.clientHeight >= el.scrollHeight - 160) {
    fetchPage(page.value + 1, true);
  }
}

async function addToShelf(r: SearchResultView) {
  const cur = active.value;
  if (!cur) return;
  try {
    // 书名/作者必须带上：书源详情页规则取不到书名时靠它兜底。
    // variable 是书源在列表页 @put 的变量，目录/正文的 @get 依赖它。
    await sourceApi.addToShelf(
      cur.sourceId,
      r.bookUrl,
      r.name,
      r.author,
      r.variable ?? "",
      0,
    );
    ElMessage.success(`《${r.name}》已加入书架`);
  } catch (e) {
    ElMessage.error((e as Error).message);
  }
}

/**
 * 点书籍行 → 详情页。
 *
 * 详情页要按 book id 取目录与进度，所以先把这本书入库；但用 previewBook
 * 而不是 addToShelf——只是点开看看，不该悄悄进书架（后端标记为试读，
 * 书架列表不展示）。用户点「加入书架」或在阅读器退出时确认才转正。
 */
const opening = ref("");
async function openBook(r: SearchResultView) {
  const cur = active.value;
  if (!cur || opening.value) return;
  opening.value = r.bookUrl;
  try {
    const brief = await sourceApi.previewBook(
      cur.sourceId,
      r.bookUrl,
      r.name,
      r.author,
      r.variable ?? "",
    );
    if (!brief) return;
    router.push({ name: "book", params: { id: String(brief.id) } });
  } catch (e) {
    ElMessage.error((e as Error).message);
  } finally {
    opening.value = "";
  }
}
</script>

<template>
  <div class="explore">
    <!-- 一级：书源手风琴列表 -->
    <template v-if="!active">
      <header class="bar">
        <h2 class="bar-title">发现</h2>
        <div class="bar-search">
          <svg class="search-icon" viewBox="0 0 24 24" aria-hidden="true">
            <circle cx="11" cy="11" r="7" />
            <path d="M20 20l-3.6-3.6" />
          </svg>
          <input
            v-model="filter"
            class="search-input"
            type="text"
            placeholder="筛选"
            spellcheck="false"
          />
          <button v-if="filter" class="clear" title="清空" @click="filter = ''">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>
        <el-select
          v-if="groups.length > 0"
          v-model="group"
          class="group-pick"
          size="small"
          clearable
          placeholder="分组"
        >
          <el-option v-for="g in groups" :key="g" :label="g" :value="g" />
        </el-select>
      </header>

      <div ref="listScroll" class="scroll">
        <div class="list">
          <!-- 原版空态就是一个居中的 TextView -->
          <p v-if="!booting && visibleSources.length === 0" class="empty">
            {{
              sources.length === 0
                ? "暂无发现书源，请先在「书源」页导入或检查规则"
                : "没有匹配的书源"
            }}
          </p>

          <section
            v-for="s in visibleSources"
            :key="s.id"
            :ref="(el) => setItemRef(s.id, el)"
            class="src"
          >
            <div class="src-head" @click="toggle(s.id)">
              <span class="src-name" :title="s.name">{{ s.name }}</span>
              <span v-if="stateOf(s.id)?.loading" class="spinner" />
              <svg
                class="chev"
                :class="{ open: expanded === s.id }"
                viewBox="0 0 24 24"
                aria-hidden="true"
              >
                <path d="M9 5l7 7-7 7" />
              </svg>
            </div>

            <div v-if="expanded === s.id" class="src-kinds">
              <template v-if="stateOf(s.id)?.loading">
                <span class="kinds-hint">正在解析分类…</span>
              </template>
              <template v-else-if="stateOf(s.id)?.error">
                <span class="kinds-hint error">{{ stateOf(s.id)?.error }}</span>
              </template>
              <template v-else-if="kindsOf(s.id).length">
                <button
                  v-for="k in kindsOf(s.id)"
                  :key="k.title + k.url"
                  class="kind"
                  :class="{ disabled: !k.url, error: k.title.startsWith('ERROR') }"
                  :title="k.url || k.title"
                  @click="openKind(s.id, k)"
                >
                  {{ k.title }}
                </button>
              </template>
              <template v-else>
                <span class="kinds-hint">该源没有解析出分类</span>
              </template>
            </div>
          </section>
        </div>
      </div>
    </template>

    <!-- 二级：分类书单（原版是独立 Activity，整页替换） -->
    <template v-else>
      <header class="bar">
        <button class="back" title="返回发现" @click="backToSources">
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M15 5l-7 7 7 7" />
          </svg>
        </button>
        <h2 class="bar-title">{{ active.kind.title }}</h2>
        <span class="bar-sub">{{ active.sourceName }}</span>
        <div class="bar-fill" />
        <button
          class="icon-btn"
          title="重新加载"
          :disabled="loadingBooks"
          @click="fetchPage(1, false)"
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M20 11a8 8 0 10-2.3 5.7" />
            <path d="M20 4v7h-7" />
          </svg>
        </button>
      </header>

      <div ref="bookScroll" class="scroll" @scroll.passive="onBookScroll">
        <div class="books">
          <p v-if="!books.length && loadedOnce" class="empty">
            该分类没有返回书籍
          </p>

          <article
            v-for="(r, i) in books"
            :key="r.bookUrl || i"
            class="book"
            :class="{ opening: opening === r.bookUrl }"
            @click="openBook(r)"
          >
            <div class="cover">
              <img
                v-if="r.cover && !brokenCover[r.cover]"
                :src="coverURL(r.cover)"
                :alt="r.name"
                loading="lazy"
                @error="markCoverBroken(r.cover)"
              />
              <span v-else class="cover-fallback">{{ r.name.slice(0, 1) }}</span>
            </div>

            <div class="book-main">
              <div class="book-name" :title="r.name">{{ r.name }}</div>
              <div class="book-author">{{ r.author || "佚名" }}</div>
              <div v-if="r.kind" class="book-kinds">{{ r.kind }}</div>
              <div v-if="r.lastChapter" class="book-line" :title="r.lastChapter">
                {{ r.lastChapter }}
              </div>
              <div v-if="r.intro" class="book-intro">{{ r.intro }}</div>
            </div>

            <button
              class="shelf-btn"
              title="加入书架"
              @click.stop="addToShelf(r)"
            >
              加入书架
            </button>
          </article>

          <div v-if="books.length" class="footer">
            <template v-if="loadingBooks">
              <span class="spinner" />
              <span>加载中…</span>
            </template>
            <button
              v-else-if="noMore"
              class="footer-btn"
              disabled
            >{{ paged ? "没有更多了" : "该分类不支持翻页" }}</button>
            <button v-else class="footer-btn" @click="fetchPage(page + 1, true)">
              点击加载更多
            </button>
          </div>
        </div>
      </div>
    </template>
  </div>
</template>

<style scoped>
.explore {
  display: flex;
  flex-direction: column;
  height: 100%;
  min-height: 0;
  background: #fff;
}

/* ---- 标题栏：对应 TitleBar（标题 + view_search 搜索框，30dp 高） ---- */
.bar {
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  flex: none;
  min-width: 0;
  height: 56px;
  padding: 0 var(--r-pad);
  border-bottom: 1px solid #eef0f3;
}
.bar-title {
  flex: 0 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 17px;
  font-weight: 600;
  color: rgba(0, 0, 0, 0.87);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.bar-sub {
  flex: 0 1 auto;
  min-width: 0;
  max-width: min(100%, 220px);
  font-size: 12px;
  color: rgba(0, 0, 0, 0.45);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.bar-fill {
  flex: 1;
}
.bar-search {
  display: flex;
  align-items: center;
  gap: 6px;
  flex: 0 1 320px;
  min-width: 0;
  max-width: 100%;
  height: 30px;
  margin-left: 6px;
  padding: 0 8px;
  border-radius: 15px;
  background: rgba(0, 0, 0, 0.06);
}
.search-icon {
  flex: none;
  width: 15px;
  height: 15px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.42);
  stroke-width: 2;
  stroke-linecap: round;
}
.search-input {
  flex: 1;
  min-width: 0;
  border: none;
  outline: none;
  background: transparent;
  font-size: 13px;
  color: rgba(0, 0, 0, 0.87);
}
.search-input::placeholder {
  color: rgba(0, 0, 0, 0.38);
}
.clear {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
  width: 16px;
  height: 16px;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: rgba(0, 0, 0, 0.18);
  cursor: pointer;
}
.clear svg {
  width: 10px;
  height: 10px;
  fill: none;
  stroke: #fff;
  stroke-width: 2.4;
  stroke-linecap: round;
}
.group-pick {
  flex: none;
  width: min(100%, 120px);
  max-width: 100%;
  min-width: 0;
}
.icon-btn {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 30px;
  height: 30px;
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
  opacity: 0.45;
}
.icon-btn svg {
  width: 18px;
  height: 18px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.62);
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.back {
  display: flex;
  align-items: center;
  justify-content: center;
  flex: none;
  width: 30px;
  height: 30px;
  margin-left: -6px;
  padding: 0;
  border: none;
  border-radius: 50%;
  background: transparent;
  cursor: pointer;
}
.back:hover {
  background: rgba(0, 0, 0, 0.06);
}
.back svg {
  width: 20px;
  height: 20px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.75);
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
}

.scroll {
  flex: 1;
  min-height: 0;
  overflow-y: auto;
}

/* ---- 书源列表：整行左右 16dp、上 12dp，行与行之间 12dp ---- */
.list {
  max-width: min(100%, 960px);
  margin: 0 auto;
  padding: var(--r-pad-sm) var(--r-pad) var(--r-pad);
}
.src + .src {
  margin-top: 12px;
}

/* 灰条本体：6dp 圆角 + 10dp/6dp 内边距（item_find_book 的 ll_title） */
.src-head {
  display: flex;
  align-items: center;
  gap: 8px;
  min-width: 0;
  min-height: 32px;
  padding: 6px 10px;
  border-radius: 6px;
  background: rgba(0, 0, 0, 0.0625);
  cursor: pointer;
  user-select: none;
  transition: background 0.15s;
}
.src-head:hover {
  background: rgba(0, 0, 0, 0.095);
}
.src-name {
  flex: 1;
  min-width: 0;
  font-size: 15px;
  line-height: 20px;
  color: rgba(0, 0, 0, 0.87);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
/* 箭头 20dp，展开时右→下旋转 90°，颜色取 secondaryText */
.chev {
  flex: none;
  width: 20px;
  height: 20px;
  fill: none;
  stroke: rgba(0, 0, 0, 0.54);
  stroke-width: 2;
  stroke-linecap: round;
  stroke-linejoin: round;
  transition: transform 0.18s ease;
}
.chev.open {
  transform: rotate(90deg);
}

/* 展开体：左右再缩进 8dp，上边距 8dp，内边距 3dp */
.src-kinds {
  display: flex;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  margin: 8px 8px 0;
  padding: 3px;
  min-width: 0;
}
/* 胶囊：圆角 16dp、4dp/12dp 内边距、14sp（item_fillet_text） */
.kind {
  margin: 3px;
  padding: 4px 12px;
  border: none;
  border-radius: 16px;
  background: rgba(0, 0, 0, 0.12);
  color: rgba(0, 0, 0, 0.87);
  font-size: 14px;
  line-height: 20px;
  min-width: 0;
  max-width: min(100%, 260px);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  cursor: pointer;
  transition: background 0.15s;
}
.kind:hover {
  background: rgba(0, 0, 0, 0.2);
}
/* 没有地址的胶囊不可点，原版直接 setOnClickListener(null) */
.kind.disabled {
  background: rgba(0, 0, 0, 0.05);
  color: rgba(0, 0, 0, 0.32);
  cursor: default;
}
.kind.error {
  color: #c0392b;
}
.kinds-hint {
  margin: 3px;
  font-size: 13px;
  line-height: 20px;
  color: rgba(0, 0, 0, 0.42);
}
.kinds-hint.error {
  color: #c0392b;
}

.empty {
  margin: 16px;
  font-size: 14px;
  line-height: 1.7;
  text-align: center;
  color: rgba(0, 0, 0, 0.42);
}

/* ---- 书单：每行 80x110 封面 + 文字，行间一条细线 ---- */
.books {
  max-width: min(100%, 960px);
  margin: 0 auto;
  padding: 0 var(--r-pad-sm) var(--r-pad);
}
.book {
  display: flex;
  gap: var(--r-gap-sm);
  padding: 8px 0;
  min-width: 0;
  border-bottom: 1px solid rgba(0, 0, 0, 0.06);
  cursor: pointer;
}
.book:hover {
  background: rgba(0, 0, 0, 0.02);
}
/* 正在入库/跳转的那一本给一点反馈，避免用户以为点击没反应 */
.book.opening {
  opacity: 0.55;
  pointer-events: none;
}
.book:last-of-type {
  border-bottom: none;
}
.cover {
  flex: none;
  width: 80px;
  max-width: 100%;
  height: 110px;
  border-radius: 2px;
  overflow: hidden;
  background: #f2f3f5;
}
.cover img {
  display: block;
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.cover-fallback {
  display: flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  height: 100%;
  font-size: 22px;
  color: rgba(0, 0, 0, 0.25);
  background: #f2f3f5;
}
.book-main {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  gap: 3px;
  padding: 2px 0;
}
.book-name {
  font-size: 16px;
  line-height: 22px;
  color: rgba(0, 0, 0, 0.87);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.book-author,
.book-kinds,
.book-line {
  font-size: 12px;
  line-height: 17px;
  color: rgba(0, 0, 0, 0.6);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.book-intro {
  margin-top: 2px;
  font-size: 12px;
  line-height: 18px;
  color: rgba(0, 0, 0, 0.5);
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
/* 原版行内没有按钮，鼠标悬停才浮出来，避免破坏「纯列表」观感 */
.shelf-btn {
  align-self: flex-start;
  flex: none;
  margin-top: 2px;
  padding: 3px 10px;
  border: 1px solid rgba(0, 0, 0, 0.14);
  border-radius: 13px;
  background: #fff;
  color: rgba(0, 0, 0, 0.62);
  font-size: 12px;
  cursor: pointer;
  opacity: 0;
  transition: opacity 0.15s, color 0.15s, border-color 0.15s;
}
.book:hover .shelf-btn {
  opacity: 1;
}
/* 键盘聚焦时也要可见，否则按钮对纯键盘用户不存在 */
.shelf-btn:focus-visible {
  opacity: 1;
  outline: 2px solid #8ab4f8;
  outline-offset: 1px;
}
.shelf-btn:hover {
  border-color: #8ab4f8;
  color: #1a73e8;
  background: #f3f8ff;
}

/* 底部状态：原版 LoadMoreView，只有提示、没有翻页按钮 */
.footer {
  display: flex;
  align-items: center;
  justify-content: center;
  flex-wrap: wrap;
  gap: var(--r-gap-sm);
  padding: 16px 0 4px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.42);
}
.footer-btn {
  border: none;
  background: transparent;
  padding: 4px 8px;
  font-size: 12px;
  color: rgba(0, 0, 0, 0.42);
  cursor: pointer;
}
.footer-btn:hover:not(:disabled) {
  color: rgba(0, 0, 0, 0.62);
}
.footer-btn:disabled {
  cursor: default;
}

/* 加载转圈：原版 RotateLoading，20dp，在箭头左侧 */
.spinner {
  flex: none;
  width: 14px;
  height: 14px;
  border: 1.5px solid rgba(0, 0, 0, 0.12);
  border-top-color: rgba(0, 0, 0, 0.45);
  border-radius: 50%;
  animation: spin 0.8s linear infinite;
}
@keyframes spin {
  to {
    transform: rotate(360deg);
  }
}

/* 手机：标题栏换行后解除固定高度，搜索框占满整行；
   触屏没有 hover，让「加入书架」按钮常显 */
@media (max-width: 640px) {
  .bar {
    height: auto;
    min-height: 56px;
    padding: var(--r-pad-sm) var(--r-pad);
  }
  .bar-search {
    flex: 1 1 100%;
    margin-left: 0;
  }
  .shelf-btn {
    opacity: 1;
  }
}
</style>
