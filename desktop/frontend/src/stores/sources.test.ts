import { createPinia, setActivePinia } from "pinia";
import { beforeEach, describe, expect, it, vi } from "vitest";

/**
 * sources store 的变更通知（revision）单测。
 *
 * 守的不变量：任何改书源的操作都必须递增 revision。发现页靠它决定何时
 * 重拉 ListExploreSources——漏掉一个 mutator，用户就会看到「书源页改了、
 * 发现页还是旧的」。
 */
const h = vi.hoisted(() => ({
  list: vi.fn(),
  listGroups: vi.fn(),
}));

vi.mock("@/api/source", () => ({
  sourceApi: {
    list: (...a: unknown[]) => h.list(...a),
    listGroups: (...a: unknown[]) => h.listGroups(...a),
  },
}));

import { useSourcesStore } from "./sources";
import type { SourceView } from "@/types";

function view(id: number, name = "源"): SourceView {
  return {
    id,
    name,
    url: `https://example.com/${id}`,
    group: "",
    comment: "",
    enabled: true,
    order: 0,
    lastUpdateAt: 0,
    raw: "{}",
  } as unknown as SourceView;
}

beforeEach(() => {
  setActivePinia(createPinia());
  h.list.mockReset();
  h.listGroups.mockReset();
  h.list.mockResolvedValue([]);
  h.listGroups.mockResolvedValue([]);
});

describe("sources store 的变更通知", () => {
  it("ensureLoaded 只拉一次，且只在真正加载后递增 revision", async () => {
    const store = useSourcesStore();
    expect(store.revision).toBe(0);
    await store.ensureLoaded();
    expect(h.list).toHaveBeenCalledTimes(1);
    expect(store.revision).toBe(1);
    await store.ensureLoaded();
    expect(h.list).toHaveBeenCalledTimes(1);
    expect(store.revision).toBe(1);
  });

  it("加载失败不广播变更，且复位 loading", async () => {
    h.list.mockRejectedValueOnce(new Error("db locked"));
    const store = useSourcesStore();
    await expect(store.refresh()).rejects.toThrow("db locked");
    expect(store.revision).toBe(0);
    expect(store.loaded).toBe(false);
    expect(store.loading).toBe(false);
  });

  it("每个就地更新都递增 revision（新增/编辑/启停/发现开关/删除/分组）", async () => {
    const store = useSourcesStore();
    await store.refresh();
    const r = store.revision;

    store.upsert(view(1));
    expect(store.revision).toBe(r + 1);
    expect(store.sources).toHaveLength(1);

    store.upsert(view(1, "改名"));
    expect(store.revision).toBe(r + 2);
    expect(store.sources).toHaveLength(1);
    expect(store.sources[0].name).toBe("改名");

    store.patch(1, { enabled: false });
    expect(store.revision).toBe(r + 3);
    expect(store.sources[0].enabled).toBe(false);

    store.patchMany([1], { enabledExplore: true });
    expect(store.revision).toBe(r + 4);
    expect(store.sources[0]).toMatchObject({ enabledExplore: true });

    store.removeLocal(1);
    expect(store.revision).toBe(r + 5);
    expect(store.sources).toHaveLength(0);

    store.upsert(view(2));
    store.removeLocalMany([2]);
    expect(store.revision).toBe(r + 7);
    expect(store.sources).toHaveLength(0);

    await store.refreshGroups();
    expect(store.revision).toBe(r + 8);
  });

  it("refresh 广播一次变更（导入 / 订阅同步 / 手动刷新都走它）", async () => {
    const store = useSourcesStore();
    await store.refresh();
    const r = store.revision;
    h.list.mockResolvedValueOnce([view(9)]);
    await store.refresh();
    expect(store.revision).toBe(r + 1);
    expect(store.sources.map((s) => s.id)).toEqual([9]);
  });
});
