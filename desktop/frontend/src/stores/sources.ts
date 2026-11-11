// 书源列表状态。
//
// 为什么单独一个 store：书源页（SourceView）以前每次进 tab 都全量重拉，
// 上千书源时明显卡顿；编辑、导入、登录之后又要再拉一次。改成启动时预载
// 一份全局缓存，页面间共享，变更后就地更新，只有手动刷新才整表重拉。
//
// 约定：store 只做「数据持有 + 调用 src/api」，不掺杂 UI 交互（同 bookshelf）。
import { defineStore } from "pinia";
import { ref } from "vue";

import { sourceApi } from "@/api/source";
import type { SourceGroupView, SourceView } from "@/types";

export const useSourcesStore = defineStore("sources", () => {
  const sources = ref<SourceView[]>([]);
  /** 分组及数量：分组菜单与分组管理对话框共用。 */
  const groups = ref<SourceGroupView[]>([]);
  const loading = ref(false);
  /** 是否完成过至少一次加载：ensureLoaded 靠它避免重复请求。 */
  const loaded = ref(false);

  /**
   * 书源变更版本号：每次写操作完成后自增。
   *
   * 发现页不消费 sources —— 它走 ListExploreSources，过滤条件（启用 +
   * 开启发现 + 有 exploreUrl）在 Go 侧，返回的是更精简的 ExploreSourceBrief。
   * 光订阅 store 里的 SourceView[] 没法知道那个集合变了，所以需要一份
   * 「书源变过」的信号，让发现页重新拉一次。
   *
   * bump 放在每个 mutator 内部，而不是让调用方手动广播：书源页有十几个
   * 变更入口（增删改、启停、导入、分组、拖拽…），漏一个就会重现
   * 「书源页加了源、发现页看不到」的 bug。
   */
  const revision = ref(0);
  function bump() {
    revision.value += 1;
  }

  /** 整表重拉。手动刷新、导入/订阅变更后调用。 */
  async function refresh() {
    loading.value = true;
    try {
      // 两条请求互不依赖，并行发出——串行时进页会白等一个往返。
      const [list, gs] = await Promise.all([
        sourceApi.list(""),
        sourceApi.listGroups(),
      ]);
      sources.value = list;
      groups.value = gs;
      loaded.value = true;
      bump();
    } finally {
      loading.value = false;
    }
  }

  /** 只刷分组（增删分组后调用，不必重拉全部书源）。 */
  async function refreshGroups() {
    groups.value = await sourceApi.listGroups();
    // 分组改名会改到发现页书源的 group 字段（它的分组下拉从简表派生）。
    bump();
  }

  /** 启动预载 / 进页面时调用：已经加载过就不再请求。 */
  async function ensureLoaded() {
    if (!loaded.value) await refresh();
  }

  /** 编辑保存后就地更新条目（新保存的书源插入列表），不整表刷新。 */
  function upsert(view: SourceView) {
    const i = sources.value.findIndex((s) => s.id === view.id);
    if (i >= 0) sources.value[i] = view;
    else sources.value.push(view);
    bump();
  }

  /**
   * 就地打补丁（启停、发现开关、分组）。
   *
   * 批量操作的返回值只是一句 nil，没法回填；这些字段前端本来就能算出来，
   * 就地改比整表重拉快得多，也避免列表在操作后跳动。
   */
  function patch(id: number, fields: Partial<SourceView>) {
    const i = sources.value.findIndex((s) => s.id === id);
    if (i >= 0) sources.value[i] = { ...sources.value[i], ...fields };
    bump();
  }

  function patchMany(ids: number[], fields: Partial<SourceView>) {
    const set = new Set(ids);
    sources.value = sources.value.map((s) =>
      set.has(s.id) ? { ...s, ...fields } : s,
    );
    bump();
  }

  /** 删除后就地移除，不整表刷新。 */
  function removeLocal(id: number) {
    sources.value = sources.value.filter((s) => s.id !== id);
    bump();
  }

  function removeLocalMany(ids: number[]) {
    const set = new Set(ids);
    sources.value = sources.value.filter((s) => !set.has(s.id));
    bump();
  }

  return {
    sources,
    groups,
    loading,
    loaded,
    revision,
    refresh,
    refreshGroups,
    ensureLoaded,
    upsert,
    patch,
    patchMany,
    removeLocal,
    removeLocalMany,
  };
});
