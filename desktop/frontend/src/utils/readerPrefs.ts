/**
 * 阅读器外观偏好的持久化。
 *
 * 字号/行距属于「一次调好、以后都想要」的设置，放在 localStorage 里按用户
 * 全局保存（WebView2 的 localStorage 落在用户数据目录，重启不丢）。
 * 读取一律容错：存了脏数据或浏览器禁用了存储时退回默认值，不影响阅读。
 */

export interface ReaderPrefs {
  /** 正文字号（px） */
  fontSize: number;
  /** 行距倍数 */
  lineHeight: number;
}

export const readerPrefsDefaults: ReaderPrefs = { fontSize: 17, lineHeight: 1.9 };

const STORAGE_KEY = "legado.reader.prefs";
const FONT_SIZE_RANGE: [number, number] = [14, 28];
const LINE_HEIGHT_RANGE: [number, number] = [1.2, 3];

/** 把数值夹到合法区间；非数字时取默认值。 */
function clamp(value: unknown, min: number, max: number, fallback: number) {
  const n = typeof value === "number" ? value : Number(value);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
}

/** 读取阅读偏好。任何异常都退回默认值。 */
export function loadReaderPrefs(): ReaderPrefs {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    return { ...readerPrefsDefaults };
  }
  if (!raw) return { ...readerPrefsDefaults };

  try {
    const parsed = JSON.parse(raw) as Partial<ReaderPrefs>;
    return {
      fontSize: clamp(
        parsed.fontSize,
        FONT_SIZE_RANGE[0],
        FONT_SIZE_RANGE[1],
        readerPrefsDefaults.fontSize,
      ),
      lineHeight: clamp(
        parsed.lineHeight,
        LINE_HEIGHT_RANGE[0],
        LINE_HEIGHT_RANGE[1],
        readerPrefsDefaults.lineHeight,
      ),
    };
  } catch {
    return { ...readerPrefsDefaults };
  }
}

/** 保存阅读偏好；写入失败（隐私模式、配额满）时静默忽略。 */
export function saveReaderPrefs(prefs: ReaderPrefs): void {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        fontSize: clamp(
          prefs.fontSize,
          FONT_SIZE_RANGE[0],
          FONT_SIZE_RANGE[1],
          readerPrefsDefaults.fontSize,
        ),
        lineHeight: clamp(
          prefs.lineHeight,
          LINE_HEIGHT_RANGE[0],
          LINE_HEIGHT_RANGE[1],
          readerPrefsDefaults.lineHeight,
        ),
      }),
    );
  } catch {
    // 存不下就算了，不打断阅读
  }
}
