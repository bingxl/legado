/**
 * 听书偏好的本地持久化。
 *
 * 与 tts/prefs.ts 同理：全局记在 localStorage，读写一律容错（隐私模式下
 * localStorage 不可写时忽略，本次会话内仍然生效）。默认值是「下次开始听书」
 * 的初始值，设置页与播放页共享同一份 key。
 */
import type { PlayMode } from "@/types/audio";

export interface AudioPrefs {
  /** 播放倍速，0.5–3.0，1 为常速。 */
  rate: number;
  /** 音量，0–1。 */
  volume: number;
  /** 章末是否自动续播下一章。 */
  autoNext: boolean;
  /** 默认定时停止分钟数，0 表示不启用。 */
  timerMinutes: number;
  /** 默认播放模式。 */
  playMode: PlayMode;
}

export const audioPrefsDefaults: AudioPrefs = {
  rate: 1,
  volume: 1,
  autoNext: true,
  timerMinutes: 0,
  playMode: "LIST_END_STOP",
};

const STORAGE_KEY = "legado.audio.prefs";
const PLAY_MODES: PlayMode[] = [
  "LIST_END_STOP",
  "SINGLE_LOOP",
  "RANDOM",
  "LIST_LOOP",
];

function clamp(value: unknown, min: number, max: number, fallback: number): number {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

function playMode(value: unknown): PlayMode {
  return PLAY_MODES.includes(value as PlayMode)
    ? (value as PlayMode)
    : audioPrefsDefaults.playMode;
}

export function loadAudioPrefs(): AudioPrefs {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    return { ...audioPrefsDefaults };
  }
  if (!raw) return { ...audioPrefsDefaults };
  try {
    const p = JSON.parse(raw) as Partial<AudioPrefs>;
    return {
      rate: clamp(p.rate, 0.5, 3, audioPrefsDefaults.rate),
      volume: clamp(p.volume, 0, 1, audioPrefsDefaults.volume),
      autoNext:
        typeof p.autoNext === "boolean" ? p.autoNext : audioPrefsDefaults.autoNext,
      timerMinutes: Math.round(
        clamp(p.timerMinutes, 0, 180, audioPrefsDefaults.timerMinutes),
      ),
      playMode: playMode(p.playMode),
    };
  } catch {
    return { ...audioPrefsDefaults };
  }
}

export function saveAudioPrefs(prefs: Partial<AudioPrefs>): void {
  const merged = { ...loadAudioPrefs(), ...prefs };
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        rate: clamp(merged.rate, 0.5, 3, audioPrefsDefaults.rate),
        volume: clamp(merged.volume, 0, 1, audioPrefsDefaults.volume),
        autoNext: merged.autoNext !== false,
        timerMinutes: Math.round(
          clamp(merged.timerMinutes, 0, 180, audioPrefsDefaults.timerMinutes),
        ),
        playMode: playMode(merged.playMode),
      }),
    );
  } catch {
    // 存不下就算了，不影响本次播放
  }
}
