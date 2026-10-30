/**
 * 朗读偏好的本地持久化（语速、音色）。
 *
 * 与 `readerPrefs` 同理：按用户全局记在 localStorage，读取一律容错。
 * M3 接上后端设置后，这里退化为「UI 偏好的本地缓存」，服务端值为准。
 */

export interface TtsPrefs {
  /** 语速百分比，50–200，100 为常速。 */
  rate: number;
  /** 上次使用的音色 id；空表示交给默认挑选。 */
  voiceId: string;
  /** 章末是否自动续读下一章。 */
  autoNext: boolean;
}

export const ttsPrefsDefaults: TtsPrefs = {
  rate: 100,
  voiceId: "",
  autoNext: true,
};

const STORAGE_KEY = "legado.tts.prefs";
const RATE_RANGE: [number, number] = [50, 200];

function clampRate(value: unknown, fallback: number): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(RATE_RANGE[1], Math.max(RATE_RANGE[0], Math.round(n)));
}

export function loadTtsPrefs(): TtsPrefs {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    return { ...ttsPrefsDefaults };
  }
  if (!raw) return { ...ttsPrefsDefaults };
  try {
    const parsed = JSON.parse(raw) as Partial<TtsPrefs>;
    return {
      rate: clampRate(parsed.rate, ttsPrefsDefaults.rate),
      voiceId: typeof parsed.voiceId === "string" ? parsed.voiceId : "",
      autoNext:
        typeof parsed.autoNext === "boolean"
          ? parsed.autoNext
          : ttsPrefsDefaults.autoNext,
    };
  } catch {
    return { ...ttsPrefsDefaults };
  }
}

export function saveTtsPrefs(prefs: Partial<TtsPrefs>): void {
  const merged = { ...loadTtsPrefs(), ...prefs };
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        rate: clampRate(merged.rate, ttsPrefsDefaults.rate),
        voiceId: merged.voiceId ?? "",
        autoNext: merged.autoNext !== false,
      }),
    );
  } catch {
    // 存不下就算了，不影响朗读
  }
}
