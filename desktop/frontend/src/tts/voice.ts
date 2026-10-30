/**
 * 系统音色（WebView `speechSynthesis`）。
 *
 * ⚠️ 头号陷阱：**首帧 `getVoices()` 返回空数组**（Windows WebView2 实测）。
 * 直接取就会拿到 `[]`，选中的音色静默失效——听感上像是"设置了没反应"。
 * 所以对外只提供 `watchSystemVoices()`：等 `voiceschanged` 或轮询到非空再回调。
 */

import type { Voice } from "./types";

export const SYSTEM_ENGINE_ID = "system";

/** 当前环境是否具备系统朗读能力。 */
export function speechSupported(): boolean {
  return (
    typeof window !== "undefined" &&
    !!window.speechSynthesis &&
    typeof window.SpeechSynthesisUtterance === "function"
  );
}

let cache: SpeechSynthesisVoice[] = [];

/** 同步读一次系统音色；尚未就绪时返回上一次的缓存（可能为空数组）。 */
export function listSystemVoices(): SpeechSynthesisVoice[] {
  if (!speechSupported()) return [];
  try {
    const now = window.speechSynthesis.getVoices();
    if (now.length) cache = now;
  } catch {
    // 个别环境 getVoices 会抛，忽略并退回缓存
  }
  return cache;
}

/**
 * 等系统音色就绪后回调一次，返回取消函数。
 * 已就绪时同步回调（仍在下一个微任务里，避免调用方在 setup 期间被同步打断）。
 */
export function watchSystemVoices(
  cb: (voices: SpeechSynthesisVoice[]) => void,
): () => void {
  if (!speechSupported()) {
    cb([]);
    return () => {};
  }
  const synth = window.speechSynthesis;
  let stopped = false;
  let timer = 0;

  const stop = () => {
    if (stopped) return;
    stopped = true;
    if (timer) window.clearInterval(timer);
    timer = 0;
    synth.removeEventListener("voiceschanged", onChanged);
  };

  const emit = (): boolean => {
    const list = listSystemVoices();
    if (!list.length) return false;
    stop();
    cb(list);
    return true;
  };

  function onChanged() {
    emit();
  }

  synth.addEventListener("voiceschanged", onChanged);
  if (!emit()) {
    // 某些 WebView 从不派发 voiceschanged，轮询兜底（10 秒后放弃）。
    let ticks = 0;
    timer = window.setInterval(() => {
      ticks += 1;
      if (emit()) return;
      if (ticks > 33) {
        stop();
        cb([]);
      }
    }, 300);
  }
  return stop;
}

/** 系统音色 → 统一的 Voice。 */
export function toVoice(v: SpeechSynthesisVoice): Voice {
  return {
    id: v.voiceURI || v.name,
    name: v.name,
    lang: v.lang,
    engineId: SYSTEM_ENGINE_ID,
    local: v.localService,
  };
}

/** 按 id 找回系统音色对象（id 优先按 voiceURI 匹配，退回 name）。 */
export function findSystemVoice(id?: string): SpeechSynthesisVoice | null {
  const list = listSystemVoices();
  if (!list.length) return null;
  if (id) {
    const hit = list.find((v) => v.voiceURI === id || v.name === id);
    if (hit) return hit;
  }
  return null;
}

/**
 * 选默认音色：优先指定值，其次中文（本机合成优先），再次第一个可用。
 * 返回 null 表示本机没有任何音色（Linux 常见），调用方应引导去用 HTTP 引擎。
 */
export function pickDefaultVoice(
  voices: Voice[],
  preferred?: string,
): Voice | null {
  if (preferred) {
    const hit = voices.find((v) => v.id === preferred || v.name === preferred);
    if (hit) return hit;
  }
  const zh = voices.filter((v) => /^zh/i.test(v.lang ?? ""));
  return zh.find((v) => v.local) ?? zh[0] ?? voices[0] ?? null;
}

/** 语言标记的中文说明，用于下拉分组。 */
export function langLabel(lang?: string): string {
  const l = (lang ?? "").toLowerCase();
  if (l.startsWith("zh")) return "中文";
  if (l.startsWith("en")) return "英文";
  if (l.startsWith("ja")) return "日文";
  if (l.startsWith("ko")) return "韩文";
  return lang || "其它";
}
