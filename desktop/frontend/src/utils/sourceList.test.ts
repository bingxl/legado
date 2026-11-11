/**
 * 书源列表筛选/排序的回归测试。
 *
 * 这些规则全是「差一点就不对」的细节：筛「启用」被当成普通关键词、
 * 「按更新时间」的升降序反了、按域名分组把 www 拆成两组——界面看上去都正常，
 * 只有实际用起来才发现不对。所以用纯函数 + 单测锁住语义。
 */
import { describe, expect, it } from "vitest";

import type { SourceView } from "@/types";
import {
  FILTER_PRESETS,
  filterSources,
  sortSources,
  sourceHost,
  splitGroups,
} from "./sourceList";

/** 造一个字段够用的书源；未指定的走默认值。 */
function src(patch: Partial<SourceView> & { id: number; name: string }): SourceView {
  return {
    group: "",
    url: `https://example.com/${patch.id}`,
    enabled: true,
    order: patch.id,
    comment: "",
    raw: "",
    lastUpdateAt: null,
    createdAt: "2026-01-01T00:00:00Z",
    type: 0,
    enabledExplore: true,
    hasExploreUrl: false,
    hasLoginUrl: false,
    enabledCookieJar: true,
    weight: 0,
    respondTime: 180000,
    variableComment: "",
    ...patch,
  } as SourceView;
}

describe("splitGroups", () => {
  it("拆分逗号分组并去重去空", () => {
    expect(splitGroups("玄幻, 完本 ,,玄幻")).toEqual(["玄幻", "完本"]);
    expect(splitGroups("")).toEqual([]);
    expect(splitGroups("  ")).toEqual([]);
  });
});

describe("sourceHost", () => {
  it("去掉 www 并取主域名", () => {
    expect(sourceHost("https://www.example.com/a/b")).toBe("example.com");
    expect(sourceHost("https://m.example.com")).toBe("example.com");
  });

  it("二级后缀取三段", () => {
    expect(sourceHost("https://book.sina.com.cn/x")).toBe("sina.com.cn");
    expect(sourceHost("https://a.co.uk")).toBe("a.co.uk");
  });

  it("IP / 无域名回落到自身或 #", () => {
    expect(sourceHost("https://127.0.0.1:8080/x")).toBe("127.0.0.1");
    // 规则型书源没有域名，归到最后一组
    expect(sourceHost("data:;base64,xxx")).toBe("#");
  });
});

describe("filterSources", () => {
  const list = [
    src({ id: 1, name: "甲", group: "玄幻", enabled: true }),
    src({ id: 2, name: "乙", group: "玄幻,完本", enabled: false }),
    src({ id: 3, name: "启用测试", group: "", enabled: true, hasLoginUrl: true }),
    src({
      id: 4,
      name: "丁",
      group: "都市",
      enabled: true,
      hasExploreUrl: true,
      enabledExplore: false,
    }),
  ];

  it("空关键词返回全部", () => {
    expect(filterSources(list, "")).toHaveLength(4);
    expect(filterSources(list, "   ")).toHaveLength(4);
  });

  it("group: 前缀按具体分组筛", () => {
    expect(filterSources(list, "group:玄幻").map((s) => s.id)).toEqual([1, 2]);
    expect(filterSources(list, "group:完本").map((s) => s.id)).toEqual([2]);
    expect(filterSources(list, "group:不存在")).toEqual([]);
  });

  it("内置筛选词优先于模糊匹配", () => {
    // 名字里带「启用」的源不该把「启用」当关键词命中，这里筛的是启用状态
    const enabled = filterSources(list, FILTER_PRESETS.enabled);
    expect(enabled.map((s) => s.id)).toEqual([1, 3, 4]);
  });

  it("禁用 / 需要登录 / 无分组", () => {
    expect(filterSources(list, FILTER_PRESETS.disabled).map((s) => s.id)).toEqual([2]);
    expect(filterSources(list, FILTER_PRESETS.needLogin).map((s) => s.id)).toEqual([3]);
    expect(filterSources(list, FILTER_PRESETS.noGroup).map((s) => s.id)).toEqual([3]);
  });

  it("启用发现要求同时有 exploreUrl", () => {
    // 4 号有地址但开关关了；1/2/3 没地址 —— 都不算「启用发现」
    expect(filterSources(list, FILTER_PRESETS.enabledExplore)).toEqual([]);
    const list2 = [
      ...list,
      src({ id: 5, name: "戊", hasExploreUrl: true, enabledExplore: true }),
    ];
    expect(
      filterSources(list2, FILTER_PRESETS.enabledExplore).map((s) => s.id),
    ).toEqual([5]);
    expect(
      filterSources(list2, FILTER_PRESETS.disabledExplore).map((s) => s.id),
    ).toEqual([1, 2, 3, 4]);
  });

  it("普通关键词按名称/分组/地址模糊匹配", () => {
    expect(filterSources(list, "玄").map((s) => s.id)).toEqual([1, 2]);
    expect(filterSources(list, "example.com/4").map((s) => s.id)).toEqual([4]);
  });
});

describe("sortSources", () => {
  const list = [
    src({ id: 1, name: "b", order: 2, weight: 5, respondTime: 300 }),
    src({ id: 2, name: "a", order: 0, weight: 1, respondTime: 100 }),
    src({ id: 3, name: "c", order: 1, weight: 9, respondTime: 200 }),
  ];

  it("手动排序按 order 升序，降序整体倒置", () => {
    expect(sortSources(list, "manual", true).map((s) => s.id)).toEqual([2, 3, 1]);
    expect(sortSources(list, "manual", false).map((s) => s.id)).toEqual([1, 3, 2]);
  });

  it("按权重", () => {
    expect(sortSources(list, "weight", true).map((s) => s.id)).toEqual([2, 1, 3]);
    expect(sortSources(list, "weight", false).map((s) => s.id)).toEqual([3, 1, 2]);
  });

  it("按响应时间", () => {
    expect(sortSources(list, "respond", true).map((s) => s.id)).toEqual([2, 3, 1]);
    expect(sortSources(list, "respond", false).map((s) => s.id)).toEqual([1, 3, 2]);
  });

  it("按名称（中文本地化比较）", () => {
    expect(sortSources(list, "name", true).map((s) => s.name)).toEqual(["a", "b", "c"]);
    expect(sortSources(list, "name", false).map((s) => s.name)).toEqual(["c", "b", "a"]);
  });

  it("按更新时间：升序时最新的在前（与原生一致）", () => {
    const data = [
      src({ id: 1, name: "old", lastUpdateAt: "2026-01-01T00:00:00Z" }),
      src({ id: 2, name: "new", lastUpdateAt: "2026-06-01T00:00:00Z" }),
    ];
    expect(sortSources(data, "update", true).map((s) => s.id)).toEqual([2, 1]);
    expect(sortSources(data, "update", false).map((s) => s.id)).toEqual([1, 2]);
  });

  it("按启用状态：升序时启用的在前", () => {
    const data = [
      src({ id: 1, name: "off", enabled: false }),
      src({ id: 2, name: "on", enabled: true }),
    ];
    expect(sortSources(data, "enable", true).map((s) => s.id)).toEqual([2, 1]);
    expect(sortSources(data, "enable", false).map((s) => s.id)).toEqual([1, 2]);
  });

  it("按域名分组时同站点聚在一起，站点内新更新的在前", () => {
    const data = [
      src({
        id: 1,
        name: "b-old",
        url: "https://www.b.com/x",
        lastUpdateAt: "2026-01-01T00:00:00Z",
      }),
      src({
        id: 2,
        name: "a-new",
        url: "https://a.com/x",
        lastUpdateAt: "2026-05-01T00:00:00Z",
      }),
      src({
        id: 3,
        name: "b-new",
        url: "https://m.b.com/x",
        lastUpdateAt: "2026-06-01T00:00:00Z",
      }),
    ];
    // a.com 在前；b.com 的两个虽然子域不同但归并到同一主域名
    expect(sortSources(data, "manual", true, true).map((s) => s.id)).toEqual([
      2, 3, 1,
    ]);
  });

  it("不修改入参数组", () => {
    const data = [src({ id: 1, name: "b", order: 1 }), src({ id: 2, name: "a", order: 0 })];
    const before = data.map((s) => s.id);
    sortSources(data, "manual", true);
    expect(data.map((s) => s.id)).toEqual(before);
  });
});
