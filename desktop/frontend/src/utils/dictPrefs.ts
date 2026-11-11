/**
 * 取词偏好的持久化。
 *
 * 与阅读排版偏好同一套约定：放 localStorage、读取容错、写入用增量。
 * 「启用取词」默认**开启**：这是阅读器新增的主功能，默认关闭等于没人会发现它；
 * 但它确实会改变选中文字后的行为，所以必须有一个总开关能关掉。
 */

export interface DictPrefs {
  /** 选中文字后是否弹出词典浮层。 */
  enabled: boolean;
  /**
   * 选中后是否自动查询。
   *
   * 关闭时只弹一个「查词」按钮——弱网/省电场景下不该每选一次就发一次请求，
   * 虽然查词本身走本地词库不联网，但请求仍要过一次 IPC。
   */
  autoLookup: boolean;
}

export const dictPrefsDefaults: DictPrefs = {
  enabled: true,
  autoLookup: true,
};

const STORAGE_KEY = "legado.dict.prefs";

/** 读取取词偏好。任何异常都退回默认值。 */
export function loadDictPrefs(): DictPrefs {
  let raw: string | null = null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    return { ...dictPrefsDefaults };
  }
  if (!raw) return { ...dictPrefsDefaults };
  try {
    const parsed = JSON.parse(raw) as Partial<DictPrefs>;
    return {
      // 老记录里没有字段时落到默认的「开」，与首次使用一致。
      enabled: parsed.enabled !== false,
      autoLookup: parsed.autoLookup !== false,
    };
  } catch {
    return { ...dictPrefsDefaults };
  }
}

/** 保存取词偏好（增量）；写入失败静默忽略。 */
export function saveDictPrefs(patch: Partial<DictPrefs>): void {
  const current = loadDictPrefs();
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        enabled: patch.enabled ?? current.enabled,
        autoLookup: patch.autoLookup ?? current.autoLookup,
      }),
    );
  } catch {
    // 存不下不打断阅读
  }
}
