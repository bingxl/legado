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
import type { SourceView } from "@/types";

export const useSourcesStore = defineStore("sources", () => {
  const sources = ref<SourceView[]>([]);
  const loading = ref(false);
  /** 是否完成过至少一次加载：ensureLoaded 靠它避免重复请求。 */
  const loaded = ref(false);

  /** 整表重拉。手动刷新、导入/订阅变更后调用。 */
  async function refresh() {
    loading.value = true;
    try {
      sources.value = await sourceApi.list("");
      loaded.value = true;
    } finally {
      loading.value = false;
    }
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
  }

  /** 删除后就地移除，不整表刷新。 */
  function removeLocal(id: number) {
    sources.value = sources.value.filter((s) => s.id !== id);
  }

  return { sources, loading, loaded, refresh, ensureLoaded, upsert, removeLocal };
});
