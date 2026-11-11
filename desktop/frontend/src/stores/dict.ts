/**
 * 取词与词库管理状态。
 *
 * 为什么放 store 而不是全塞进阅读器：
 *   - 取词偏好在设置页里改，阅读器要立刻生效（同一份 localStorage → 同一份 ref）；
 *   - 扩展包安装是后台任务，用户可以退出阅读器去设置页看进度，
 *     进度事件必须活得比组件久，否则「装到一半离开页面」就再也看不到状态。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { dictApi } from "@/api/dict";
import type {
  DictResultView,
  DictSourceConfigView,
  DictSourceView,
  DictStatusView,
} from "@/api/dict";
import { onDictInstallProgress } from "@/api/events";
import type { DictInstallProgressPayload } from "@/api/events";
import { toMessage } from "@/api/client";
import { SystemSpeaker } from "@/tts/SystemSpeaker";
import { loadDictPrefs, saveDictPrefs } from "@/utils/dictPrefs";

/** 选区在视口里的位置，浮层据此定位。 */
export interface DictAnchor {
  left: number;
  top: number;
  width: number;
  height: number;
}

/** 一次安装的进度视图。 */
export interface DictInstallView {
  packId: string;
  phase: string;
  /** 0–100；total 未知时为 null（显示不确定进度）。 */
  percent: number | null;
  bytes: number;
  totalBytes: number;
  sourceName: string;
  switchedFrom: string;
  message: string;
  /** 事件序号，用于丢弃迟到事件。 */
  seq: number;
  entries: number;
  /** 结束态：done / failed / canceled 都算结束，进度条不再显示。 */
  finished: boolean;
}

function toView(p: DictInstallProgressPayload): DictInstallView {
  let percent: number | null = null;
  if (p.phase === "verify") {
    percent = Math.min(100, Math.max(0, p.done));
  } else if (p.total > 0) {
    percent = Math.min(100, Math.round((p.done / p.total) * 100));
  }
  return {
    packId: p.packId,
    phase: p.phase,
    percent,
    bytes: p.bytes,
    totalBytes: p.totalBytes,
    sourceName: p.sourceName ?? "",
    switchedFrom: p.switchedFrom ?? "",
    message: p.message ?? "",
    seq: p.seq,
    entries: p.entries ?? 0,
    finished: p.phase === "done" || p.phase === "failed" || p.phase === "canceled",
  };
}

export const useDictStore = defineStore("dict", () => {
  const prefs = loadDictPrefs();
  const enabled = ref(prefs.enabled);
  const autoLookup = ref(prefs.autoLookup);

  // ── 浮层 ──────────────────────────────────────────────────
  const visible = ref(false);
  const loading = ref(false);
  const error = ref("");
  const result = ref<DictResultView | null>(null);
  const anchor = ref<DictAnchor | null>(null);
  /** 移动端取词模式：点词即查，不产生选区。 */
  const picking = ref(false);

  // ── 词库包 ────────────────────────────────────────────────
  const status = ref<DictStatusView | null>(null);
  const installs = ref<Record<string, DictInstallView>>({});
  let unsubscribe: (() => void) | null = null;

  const speaker = new SystemSpeaker();

  /** 正在安装的包，供阅读器/设置页显示全局进度。 */
  const running = computed(() =>
    Object.values(installs.value).filter((i) => !i.finished),
  );

  function setEnabled(v: boolean) {
    enabled.value = v;
    saveDictPrefs({ enabled: v });
    if (!v) close();
  }

  function setAutoLookup(v: boolean) {
    autoLookup.value = v;
    saveDictPrefs({ autoLookup: v });
  }

  function setPicking(v: boolean) {
    picking.value = v;
    if (v) close();
  }

  /**
   * 打开浮层并（可选）查询。
   *
   * 先显示锚点再查询：慢查询时用户至少能看到「这里有个东西在加载」，
   * 而不是点完一秒内毫无反应。
   */
  function openAt(text: string, rect: DictAnchor) {
    const query = text.trim();
    if (!query) return;
    anchor.value = rect;
    visible.value = true;
    if (autoLookup.value) {
      void lookup(query);
    } else {
      error.value = "";
      loading.value = false;
      result.value = {
        query,
        direction: "",
        source: "",
        matchedBy: "none",
        entries: [],
      } as DictResultView;
    }
  }

  /** 查词。并发时以最后一次为准（用户可能连着选了两个词）。 */
  let lookupToken = 0;
  async function lookup(text: string, hint: "auto" | "en" | "zh" = "auto") {
    const token = ++lookupToken;
    loading.value = true;
    error.value = "";
    try {
      const res = await dictApi.lookup(text, hint);
      if (token !== lookupToken) return;
      result.value = res;
    } catch (err) {
      if (token !== lookupToken) return;
      error.value = toMessage(err);
      result.value = null;
    } finally {
      if (token === lookupToken) loading.value = false;
    }
  }

  function close() {
    visible.value = false;
    loading.value = false;
    error.value = "";
    result.value = null;
    anchor.value = null;
  }

  /** 朗读单词。中文词用中文音色，英文词用英文音色由系统自行选择。 */
  function speak(word: string) {
    speaker.speak({ text: word, rate: 0.9 });
  }

  // ── 词库包状态与安装 ──────────────────────────────────────

  async function loadStatus() {
    try {
      status.value = await dictApi.status();
    } catch (err) {
      error.value = toMessage(err);
    }
  }

  async function sources(packId: string): Promise<DictSourceView[]> {
    return dictApi.sources(packId);
  }

  async function sourceConfig(packId: string): Promise<DictSourceConfigView> {
    return dictApi.sourceConfig(packId);
  }

  async function setSource(
    mode: "auto" | "manual",
    sourceId: string,
    customUrl: string,
  ) {
    await dictApi.setSource(mode, sourceId, customUrl);
  }

  async function probe(packId: string, sourceId: string, customUrl = "") {
    return dictApi.probe(packId, sourceId, customUrl);
  }

  /** 开始安装。进度不在这里维护——由事件驱动，避免「点了没反应」。 */
  async function install(packId: string, sourceId = "", customUrl = "") {
    await dictApi.install(packId, sourceId, customUrl);
  }

  async function retry(packId: string, sourceId = "", customUrl = "") {
    await dictApi.retry(packId, sourceId, customUrl);
  }

  async function cancel(packId: string) {
    await dictApi.cancel(packId);
  }

  async function remove(packId: string) {
    await dictApi.remove(packId);
    await loadStatus();
  }

  async function importFile(packId: string, path: string) {
    await dictApi.importFile(packId, path);
  }

  /**
   * 订阅安装进度（重复调用无副作用）。
   *
   * 按 seq 丢弃过期事件：异步投递会乱序，「已完成」被一条迟到的
   * 「下载中」打回进行中是这类长任务最典型的显示 bug。
   */
  function attach() {
    if (unsubscribe) return;
    unsubscribe = onDictInstallProgress((p) => {
      const prev = installs.value[p.packId];
      if (prev && p.seq <= prev.seq) return;
      const view = toView(p);
      installs.value = { ...installs.value, [p.packId]: view };
      if (view.finished) {
        // 状态变化（装上/失败）都要重读一次，界面才有「已安装」而不是旧状态。
        void loadStatus();
      }
    });
  }

  function detach() {
    unsubscribe?.();
    unsubscribe = null;
  }

  return {
    enabled,
    autoLookup,
    picking,
    visible,
    loading,
    error,
    result,
    anchor,
    status,
    installs,
    running,
    setEnabled,
    setAutoLookup,
    setPicking,
    openAt,
    lookup,
    close,
    speak,
    loadStatus,
    sources,
    sourceConfig,
    setSource,
    probe,
    install,
    retry,
    cancel,
    remove,
    importFile,
    attach,
    detach,
  };
});
