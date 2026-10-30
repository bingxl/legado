// 书源编辑器的状态。
//
// 为什么要单独一个 store 而不是全塞在页面里：编辑页被拆成了「分组表单 /
// 调试面板 / JSON 视图 / 源列表」几个组件，它们都要读同一份书源数据，
// 调试面板还得拿**未保存的草稿**去跑规则——这是它存在的全部意义。
import { defineStore } from "pinia";
import { computed, ref, shallowRef } from "vue";

import { sourceApi } from "@/api/source";
import type { SourceView } from "@/types";
import { BOOK_SOURCE_GROUPS, BOOK_SOURCE_FIELDS } from "@/config/sourceFields";

/** 书源在存取时用的 JSON 对象形态。字段名与 Legado 完全一致，不做驼峰转换。 */
export type SourceJson = Record<string, unknown>;

/** 新建书源时的骨架：把几个布尔开关给上默认值，避免首次保存写出 null。 */
function emptySource(): SourceJson {
  return {
    bookSourceName: "",
    bookSourceUrl: "",
    bookSourceGroup: "",
    bookSourceComment: "",
    bookSourceType: 0,
    enabled: true,
    enabledExplore: true,
    enabledCookieJar: true,
    customOrder: 0,
    weight: 0,
    ruleSearch: {},
    ruleExplore: {},
    ruleBookInfo: {},
    ruleToc: {},
    ruleContent: {},
  };
}

/** 按路径读值，任一中间层缺失都返回 undefined。 */
function readPath(obj: SourceJson, path: string[]): unknown {
  let cur: unknown = obj;
  for (const key of path) {
    if (cur === null || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

/** 按路径写值，中间层不存在时自动建对象。 */
function writePath(obj: SourceJson, path: string[], value: unknown): void {
  let cur: Record<string, unknown> = obj;
  for (let i = 0; i < path.length - 1; i++) {
    const key = path[i];
    const next = cur[key];
    if (next === null || typeof next !== "object") {
      cur[key] = {};
    }
    cur = cur[key] as Record<string, unknown>;
  }
  cur[path[path.length - 1]] = value;
}

function asString(v: unknown): string {
  if (typeof v === "string") return v;
  if (v === null || v === undefined) return "";
  return String(v);
}

/** 编辑历史的最大步数：够用来回试错，又不至于把内存撑起来。 */
const HISTORY_LIMIT = 40;

export const useSourceEditStore = defineStore("sourceEdit", () => {
  const id = ref(0);
  const json = ref<SourceJson>(emptySource());
  const loading = ref(false);
  const saving = ref(false);
  /**
   * 打开（或上次保存）时的 JSON 快照。
   *
   * dirty 由「当前内容 vs 快照」推出，而不是每次改动手动置位：
   * 手置的话，用户改一下再撤销回来仍显示「未保存」，而实际上内容没变，
   * 离开时还要弹一次没必要的确认。
   */
  const baseline = ref("");
  /** JSON 视图的文本；与 json 双向同步，解析失败时保留用户原文。 */
  const rawText = ref("");
  const rawError = ref("");
  const activeGroup = ref(BOOK_SOURCE_GROUPS[0].key);
  const activeTool = ref<"json" | "debug" | "help">("json");

  const history = shallowRef<string[]>([]);
  const historyCursor = ref(-1);
  let snapshotTimer: number | null = null;

  /** 是否有未保存的修改。 */
  const dirty = computed(() => serialize() !== baseline.value);

  const canUndo = computed(() => historyCursor.value > 0);
  const canRedo = computed(() => historyCursor.value >= 0 && historyCursor.value < history.value.length - 1);

  const name = computed(() => asString(json.value.bookSourceName));
  const url = computed(() => asString(json.value.bookSourceUrl));
  const group = computed(() => asString(json.value.bookSourceGroup));

  /** 缺哪些必填项（用于保存前的提示，比「参数不合法」有用得多）。 */
  const missingRequired = computed(() =>
    BOOK_SOURCE_FIELDS.filter((f) => f.required && asString(readPath(json.value, f.path)).trim() === "").map(
      (f) => f.title,
    ),
  );

  function serialize(): string {
    return JSON.stringify(json.value, null, 2);
  }

  /** 把当前状态压进历史栈。debounce 由调用方控制。 */
  function snapshot(): void {
    const text = serialize();
    const cur = history.value[historyCursor.value];
    if (cur === text) return;
    const next = history.value.slice(0, historyCursor.value + 1);
    next.push(text);
    if (next.length > HISTORY_LIMIT) next.shift();
    history.value = next;
    historyCursor.value = next.length - 1;
  }

  /** 输入类改动合并压栈：连续打字只在停下 500ms 后记一步。 */
  function scheduleSnapshot(): void {
    if (snapshotTimer !== null) window.clearTimeout(snapshotTimer);
    snapshotTimer = window.setTimeout(() => {
      snapshotTimer = null;
      snapshot();
    }, 500);
  }

  function reset(v?: SourceView): void {
    id.value = v?.id ?? 0;
    if (v?.raw) {
      try {
        json.value = JSON.parse(v.raw) as SourceJson;
      } catch {
        // 库里存的 raw 不合法（历史脏数据）：不阻断编辑，退化成空源并提示。
        json.value = emptySource();
        rawError.value = "书源 JSON 解析失败，已按空白源打开";
      }
      // 视图层单独存的 name/url 可能比 raw 新（历史导入路径），补回 JSON。
      if (v.name && !json.value.bookSourceName) json.value.bookSourceName = v.name;
      if (v.url && !json.value.bookSourceUrl) json.value.bookSourceUrl = v.url;
      if (v.group && !json.value.bookSourceGroup) json.value.bookSourceGroup = v.group;
    } else {
      json.value = emptySource();
    }
    rawText.value = serialize();
    rawError.value = "";
    baseline.value = serialize();
    loading.value = false;
    history.value = [];
    historyCursor.value = -1;
    snapshot();
  }

  function openNew(): void {
    reset();
  }

  async function open(sourceID: number): Promise<void> {
    loading.value = true;
    try {
      const view = await sourceApi.get(sourceID);
      reset(view);
    } finally {
      loading.value = false;
    }
  }

  function getField(path: string[]): unknown {
    return readPath(json.value, path);
  }

  function setField(path: string[], value: unknown): void {
    writePath(json.value, path, value);
    rawText.value = serialize();
    scheduleSnapshot();
  }

  /** 应用 JSON 视图里的文本。返回是否成功，失败时 rawError 有原因。 */
  function applyRawText(text: string): boolean {
    rawText.value = text;
    try {
      const parsed = JSON.parse(text) as unknown;
      if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
        rawError.value = "书源 JSON 必须是一个对象";
        return false;
      }
      json.value = parsed as SourceJson;
      rawError.value = "";
      scheduleSnapshot();
      return true;
    } catch (e) {
      rawError.value = (e as Error).message;
      return false;
    }
  }

  function undo(): void {
    if (!canUndo.value) return;
    historyCursor.value -= 1;
    json.value = JSON.parse(history.value[historyCursor.value]) as SourceJson;
    rawText.value = serialize();
  }

  function redo(): void {
    if (!canRedo.value) return;
    historyCursor.value += 1;
    json.value = JSON.parse(history.value[historyCursor.value]) as SourceJson;
    rawText.value = serialize();
  }

  /** 保存到库。返回保存后的视图；校验不通过时抛出可直接展示的错误。 */
  async function save(): Promise<SourceView> {
    const srcURL = asString(json.value.bookSourceUrl).trim();
    if (!srcURL) throw new Error("请填写「源域名」（bookSourceUrl）");
    const missing = missingRequired.value;
    if (missing.length > 0) throw new Error(`还有必填项没填：${missing.join("、")}`);
    if (rawError.value) throw new Error(`JSON 有语法错误：${rawError.value}`);

    saving.value = true;
    try {
      const view = await sourceApi.save(
        id.value,
        asString(json.value.bookSourceName),
        asString(json.value.bookSourceGroup),
        srcURL,
        asString(json.value.bookSourceComment),
        // 兼容字段：Legado 的 enabled 在书源 JSON 里可能不存在，缺省视为启用。
        serialize(),
        json.value.enabled === undefined ? true : Boolean(json.value.enabled),
        Number(json.value.customOrder ?? 0) || 0,
      );
      id.value = view.id;
      baseline.value = serialize();
      snapshot();
      return view;
    } finally {
      saving.value = false;
    }
  }

  /** 当前草稿的 JSON 文本，调试时原样传给后端（不需要先保存）。 */
  function draftRaw(): string {
    return serialize();
  }

  return {
    id,
    json,
    loading,
    saving,
    dirty,
    rawText,
    rawError,
    activeGroup,
    activeTool,
    name,
    url,
    group,
    canUndo,
    canRedo,
    missingRequired,
    open,
    openNew,
    reset,
    getField,
    setField,
    applyRawText,
    undo,
    redo,
    save,
    draftRaw,
    serialize,
  };
});
