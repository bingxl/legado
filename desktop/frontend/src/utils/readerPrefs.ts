/**
 * 阅读器外观偏好的持久化。
 *
 * 字号/行距属于「一次调好、以后都想要」的设置，放在 localStorage 里按用户
 * 全局保存（WebView2 的 localStorage 落在用户数据目录，重启不丢）。
 * 读取一律容错：存了脏数据或浏览器禁用了存储时退回默认值，不影响阅读。
 */
import { reactive, watch } from "vue";

export interface ReaderPrefs {
  /** 正文字号（px） */
  fontSize: number;
  /** 行距倍数 */
  lineHeight: number;
  /**
   * 离开阅读器（书籍与漫画共用同一个阅读器）时，若这本书还只是试读，
   * 是否弹窗询问「加入书架」。
   *
   * 默认**关闭**：从搜索/发现点开一本书往往只是想看两章，退出时被拦一次
   * 询问属于打断；需要这个提醒的人在设置里打开即可。
   */
  promptAddToShelf: boolean;
}

export const readerPrefsDefaults: ReaderPrefs = {
  fontSize: 17,
  lineHeight: 1.9,
  promptAddToShelf: false,
};

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
      // 只认严格的 true：老版本存下的记录里没有这个字段，必须落到默认的关闭。
      promptAddToShelf: parsed.promptAddToShelf === true,
    };
  } catch {
    return { ...readerPrefsDefaults };
  }
}

/**
 * 保存阅读偏好；写入失败（隐私模式、配额满）时静默忽略。
 *
 * 参数是**增量**而不是全量：设置页改字号时不带开关、阅读器的字号滑块同理，
 * 若按全量写入，任何一个调用点漏传字段都会把另一处设置静默重置。
 */
export function saveReaderPrefs(patch: Partial<ReaderPrefs>): void {
  const current = loadReaderPrefs();
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        fontSize: clamp(
          patch.fontSize ?? current.fontSize,
          FONT_SIZE_RANGE[0],
          FONT_SIZE_RANGE[1],
          readerPrefsDefaults.fontSize,
        ),
        lineHeight: clamp(
          patch.lineHeight ?? current.lineHeight,
          LINE_HEIGHT_RANGE[0],
          LINE_HEIGHT_RANGE[1],
          readerPrefsDefaults.lineHeight,
        ),
        promptAddToShelf:
          patch.promptAddToShelf ?? (current.promptAddToShelf === true),
      }),
    );
  } catch {
    // 存不下就算了，不打断阅读
  }
}

/**
 * 阅读器里**共享**的字号与行距。
 *
 * 为什么不是每个窗格各存一份 ref：分屏时两栏字号不一致会非常割裂，
 * 而在左栏调字号还要有个"顺手把右栏也改了"的副作用——两栏读同一份状态
 * 就没有这个问题。状态放在模块级单例里，窗格谁先挂载谁初始化，
 * 之后两边是同一个 reactive 对象。
 *
 * 落盘仍然复用 `saveReaderPrefs`（增量写入），所以在设置页改字号、
 * 在这里拖滑块，走的是同一条路径。
 */
export type ReaderStyle = Pick<ReaderPrefs, "fontSize" | "lineHeight">;

let sharedStyle: ReaderStyle | null = null;

export function useReaderStyle(): ReaderStyle {
  if (sharedStyle) return sharedStyle;
  const prefs = loadReaderPrefs();
  const state = reactive<ReaderStyle>({
    fontSize: prefs.fontSize,
    lineHeight: prefs.lineHeight,
  });
  // 只注册一次：两个窗格都调 useReaderStyle 时不该有两份 watcher 抢着写。
  watch(
    () => [state.fontSize, state.lineHeight],
    () => saveReaderPrefs({ fontSize: state.fontSize, lineHeight: state.lineHeight }),
  );
  sharedStyle = state;
  return state;
}
