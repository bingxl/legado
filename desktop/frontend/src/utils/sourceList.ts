/**
 * 书源列表的筛选与排序。
 *
 * 全部语义对齐 Legado 原生的 BookSourceActivity：
 *  - 搜索框除了关键词，还接受 `group:分组名` 与几个内置筛选词
 *    （启用 / 禁用 / 需要登录 / 无分组 / 启用发现 / 禁用发现）；
 *  - 排序有 7 种，且都受「升序/降序」开关影响，其中「按更新时间」在升序下
 *    反而是最新的在前（原生就是这么写的，别自作主张改）；
 *  - 开启「按域名分组」后，先按站点主域名聚在一起，域名内按更新时间倒序。
 *
 * 单独抽成纯函数是为了能单测：这些规则全是「差一点就不对」的细节，
 * 塞在组件里只能靠肉眼点界面验证。
 */
import type { SourceView } from "@/types";

/** 排序方式（对应原生 BookSourceSort）。 */
export type SourceSortKey =
  | "manual" // 手动排序（customOrder）
  | "weight" // 智能排序（书源权重）
  | "name"
  | "url"
  | "update" // 最近更新时间
  | "respond" // 响应时间
  | "enable"; // 启用状态

export const SORT_OPTIONS: { key: SourceSortKey; label: string }[] = [
  { key: "manual", label: "手动排序" },
  { key: "weight", label: "智能排序" },
  { key: "name", label: "按名称" },
  { key: "url", label: "按书源链接" },
  { key: "update", label: "按更新时间" },
  { key: "respond", label: "按响应时间" },
  { key: "enable", label: "按启用状态" },
];

export function sortLabel(key: SourceSortKey): string {
  return SORT_OPTIONS.find((o) => o.key === key)?.label ?? "手动排序";
}

/** 内置筛选词。与原生一致，直接用中文词（用户看得懂、输入快）。 */
export const FILTER_PRESETS = {
  enabled: "启用",
  disabled: "禁用",
  needLogin: "需要登录",
  noGroup: "无分组",
  enabledExplore: "启用发现",
  disabledExplore: "禁用发现",
} as const;

/** 搜索框里的分组筛选前缀。 */
export const GROUP_PREFIX = "group:";

/** 拆分书源分组串（原生允许逗号分隔多分组）。 */
export function splitGroups(group: string): string[] {
  return group
    .split(",")
    .map((g) => g.trim())
    .filter((g, i, arr) => g !== "" && arr.indexOf(g) === i);
}

/**
 * 取书源的主域名，用于「按域名分组」。
 *
 * 原生用 NetworkUtils.getSubDomainOrNull（eTLD+1）。这里不引入公共后缀表，
 * 用「最后两段、遇到 com.cn 这类二级后缀取三段」的近似规则：书源站点几乎
 * 全是常见后缀，近似足够把同一个站的不同子域聚到一起，而这正是该功能的目的。
 */
export function sourceHost(url: string): string {
  let host = "";
  try {
    host = new URL(url).hostname.toLowerCase();
  } catch {
    return "#"; // 规则型书源（data:/js: 开头）没有域名，归到最后一组
  }
  if (!host) return "#";
  host = host.replace(/^www\./, "");
  // 纯 IP 或 localhost 原样返回
  if (/^[\d.]+$/.test(host) || !host.includes(".")) return host;

  const parts = host.split(".");
  const secondLevel = ["com", "net", "org", "gov", "edu", "co"];
  const last2 = parts.slice(-2).join(".");
  if (
    parts.length >= 3 &&
    secondLevel.includes(parts[parts.length - 2]) &&
    parts[parts.length - 1].length === 2
  ) {
    // x.com.cn / x.co.uk 这类：取三段
    return parts.slice(-3).join(".");
  }
  return last2;
}

/** 中文比较（按拼音），与原生 cnCompare 的效果一致。 */
const collator = new Intl.Collator("zh-Hans-CN", { sensitivity: "base" });
function cnCompare(a: string, b: string): number {
  return collator.compare(a ?? "", b ?? "");
}

/**
 * 按关键词筛选。
 *
 * 判断顺序很重要：先认 `group:` 前缀与内置筛选词（它们是精确语义），
 * 再退化成模糊匹配——否则用户搜「启用」会被当成普通关键词，
 * 明明想筛启用状态却得到一堆名字里带「启用」的源。
 */
export function filterSources(
  list: SourceView[],
  keyword: string,
): SourceView[] {
  const k = keyword.trim();
  if (!k) return list;

  if (k.startsWith(GROUP_PREFIX)) {
    const group = k.slice(GROUP_PREFIX.length).trim();
    if (!group) return list;
    return list.filter((s) => splitGroups(s.group).includes(group));
  }

  switch (k) {
    case FILTER_PRESETS.enabled:
      return list.filter((s) => s.enabled);
    case FILTER_PRESETS.disabled:
      return list.filter((s) => !s.enabled);
    case FILTER_PRESETS.needLogin:
      return list.filter((s) => s.hasLoginUrl);
    case FILTER_PRESETS.noGroup:
      return list.filter((s) => splitGroups(s.group).length === 0);
    case FILTER_PRESETS.enabledExplore:
      // 「启用发现」的实际含义是「能在发现页看到」：既要总开关开着，
      // 又得配了 exploreUrl——只开开关没有地址的源在发现页是空的。
      return list.filter((s) => s.enabled && s.enabledExplore && s.hasExploreUrl);
    case FILTER_PRESETS.disabledExplore:
      return list.filter(
        (s) => !(s.enabled && s.enabledExplore && s.hasExploreUrl),
      );
    default:
      break;
  }

  const lower = k.toLowerCase();
  return list.filter(
    (s) =>
      s.name.toLowerCase().includes(lower) ||
      s.url.toLowerCase().includes(lower) ||
      s.group.toLowerCase().includes(lower),
  );
}

/**
 * 排序。
 *
 * groupByHost 打开时忽略 sort（原生同样如此）：域名分组的意义就是把
 * 「同一个站点的源」摆在一起看，再按名称排会把这个信息打散。
 */
export function sortSources(
  list: SourceView[],
  sort: SourceSortKey,
  ascending: boolean,
  groupByHost = false,
): SourceView[] {
  const data = [...list];

  if (groupByHost) {
    return data.sort((a, b) => {
      const ha = sourceHost(a.url);
      const hb = sourceHost(b.url);
      if (ha !== hb) {
        if (ha === "#") return 1;
        if (hb === "#") return -1;
        return ha < hb ? -1 : 1;
      }
      return timeOf(b) - timeOf(a);
    });
  }

  switch (sort) {
    case "weight":
      return data.sort((a, b) =>
        ascending ? a.weight - b.weight : b.weight - a.weight,
      );
    case "name":
      return data.sort((a, b) =>
        ascending ? cnCompare(a.name, b.name) : cnCompare(b.name, a.name),
      );
    case "url":
      return data.sort((a, b) =>
        ascending
          ? a.url.localeCompare(b.url)
          : b.url.localeCompare(a.url),
      );
    case "update":
      // 原生在「升序」下给的是「最新在前」（sortedByDescending lastUpdateTime），
      // 这与其它项的直觉相反，但保持与原生一致，避免两端表现不同。
      return data.sort((a, b) =>
        ascending ? timeOf(b) - timeOf(a) : timeOf(a) - timeOf(b),
      );
    case "respond":
      return data.sort((a, b) =>
        ascending
          ? a.respondTime - b.respondTime
          : b.respondTime - a.respondTime,
      );
    case "enable":
      return data.sort((a, b) => {
        const cmp = ascending
          ? Number(b.enabled) - Number(a.enabled)
          : Number(a.enabled) - Number(b.enabled);
        return cmp !== 0 ? cmp : cnCompare(a.name, b.name);
      });
    case "manual":
    default:
      // 手动排序的降序就是整体倒置（原生 else 分支 data.reversed()）
      return ascending
        ? data.sort((a, b) => a.order - b.order || cnCompare(a.name, b.name))
        : data.sort((a, b) => b.order - a.order || cnCompare(b.name, a.name));
  }
}

/** 取书源的更新时间戳（毫秒）；没有则 0。 */
function timeOf(s: SourceView): number {
  if (!s.lastUpdateAt) return 0;
  const t = Date.parse(s.lastUpdateAt);
  return Number.isFinite(t) ? t : 0;
}

/** 书源类型的中文名（编辑器顶部下拉与列表徽标共用）。 */
export const SOURCE_TYPES = ["文本", "音频", "图片", "文件"];

export function typeLabel(type: number): string {
  return SOURCE_TYPES[type] ?? "文本";
}
