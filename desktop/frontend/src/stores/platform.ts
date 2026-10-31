/**
 * 运行平台状态。
 *
 * 桌面端与安卓端共用同一批视图组件，差异只在外壳：
 * 桌面是左侧栏 + 内容区，安卓是底部 Tab + 全屏内容。
 * 因此平台判定集中在本 store，视图只消费 isMobile，不各自去探测。
 *
 * 判定来源是后端的 SystemAPI.Platform()——前端不要靠 userAgent 或视口宽度猜，
 * 那样在安卓分屏 / 平板 / 桌面窄窗口下都会误判。
 *
 * ## 强制覆盖（?ui=mobile / ?ui=desktop）
 *
 * 移动端外壳在真机之外的环境里本来是看不到的：桌面端永远返回 "desktop"。
 * 但安卓端 UI 的适配工作量不小，每次装 APK 到设备上看一眼的反馈周期太长，
 * 于是留一个覆盖开关——桌面端地址栏加 `?ui=mobile`，就能用同一套代码渲染出
 * 安卓端的外壳，直接在 Windows 上验证移动布局；`?ui=auto` 恢复后端判定。
 *
 * 覆盖值写入 localStorage，刷新后依然生效，省得每次切路由都要重新拼参数。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { systemApi } from "@/api/system";
import type { PlatformName, SafeArea } from "@/api/system";

/** localStorage 键名。 */
const OVERRIDE_KEY = "legado.ui.override";
/** URL 查询参数名。 */
const OVERRIDE_PARAM = "ui";
/**
 * 合法覆盖取值；auto 表示交回后端判定。
 *
 * mobile 是 android 的别名：对着用户说的是「移动端布局」，
 * 内部仍按后端 Platform() 的取值命名（android），两者不要混用。
 */
type Override = "auto" | "desktop" | "android" | "mobile";

function isOverride(v: unknown): v is Override {
  return v === "auto" || v === "desktop" || v === "android" || v === "mobile";
}

/** 归一化：mobile 落到 android；auto 由调用方先分支掉。 */
function normalize(v: Exclude<Override, "auto">): "desktop" | "android" {
  return v === "mobile" ? "android" : v;
}

/** 读一次 URL 参数：命中合法值就落盘并返回，否则返回 null。 */
function takeOverrideFromURL(): Override | null {
  const raw = new URLSearchParams(window.location.search).get(OVERRIDE_PARAM);
  if (!isOverride(raw)) return null;
  persist(raw);
  return raw;
}

function readStoredOverride(): Override | null {
  try {
    const v = localStorage.getItem(OVERRIDE_KEY);
    return isOverride(v) ? v : null;
  } catch {
    return null;
  }
}

/** 落盘；auto 等于清除。隐私模式下不可写时忽略——本次会话内仍然生效。 */
function persist(v: Override) {
  try {
    if (v === "auto") localStorage.removeItem(OVERRIDE_KEY);
    // 存归一化后的值：读回时不再需要别名分支。
    else localStorage.setItem(OVERRIDE_KEY, normalize(v));
  } catch {
    /* 忽略 */
  }
}

export const usePlatformStore = defineStore("platform", () => {
  const name = ref<PlatformName>("desktop");
  const safeArea = ref<SafeArea>({ top: 0, bottom: 0, left: 0, right: 0 });
  /** 平台探测是否完成。首帧渲染要等它，否则会先闪一下桌面布局。 */
  const ready = ref(false);
  /** 是否处于强制覆盖状态。为 true 时外壳会提示「非真机」。 */
  const overridden = ref(false);

  const isMobile = computed(() => name.value === "android");

  /** 安全区对应的内联样式，供外壳做刘海屏与手势条避让。 */
  const safeAreaStyle = computed(() => ({
    paddingTop: `${safeArea.value.top}px`,
    paddingBottom: `${safeArea.value.bottom}px`,
    paddingLeft: `${safeArea.value.left}px`,
    paddingRight: `${safeArea.value.right}px`,
  }));

  /**
   * 切换到指定外壳。传 null / "auto" 恢复后端判定。
   * 供外壳上的调试入口与自动化测试调用。
   */
  async function setOverride(v: Override | null) {
    const actual: PlatformName = await systemApi
      .platform()
      .catch(() => "desktop");
    const target = !v || v === "auto" ? actual : normalize(v);
    applyOverride(target, actual);
  }

  /**
   * 落地一次覆盖判定。
   *
   * **覆盖成与真机相同的值不算覆盖**：在桌面端点了「切回桌面布局」，
   * 若把 desktop 存下来，此后每次启动都会顶着一条「预览中（非真机判定）」的
   * 提示条——用户什么都没做却被警告。所以相等时直接清除。
   */
  function applyOverride(target: PlatformName, actual: PlatformName) {
    if (target === actual) {
      persist("auto");
      overridden.value = false;
      name.value = actual;
      return;
    }
    persist(target);
    overridden.value = true;
    name.value = target;
  }

  async function init() {
    // 覆盖的读取是同步的，放在 store 创建时做，首帧就是正确的外壳，
    // 不会先闪一帧桌面侧边栏再跳成底部 Tab（见文件末尾的同步段）。
    // 这里仍要探测一次真机平台，才能把「覆盖成相同值」这种情况清掉。
    let actual: PlatformName = "desktop";
    try {
      actual = await systemApi.platform();
    } catch {
      // 探测失败时保持 desktop：桌面布局在窄屏下只是难看，不会不可用。
    }
    if (overridden.value) applyOverride(name.value, actual);
    else name.value = actual;

    try {
      safeArea.value = await systemApi.safeArea();
    } catch {
      /* 安全区拿不到就按 0 处理 */
    }
    ready.value = true;
  }

  // ── 同步部分：在 store 创建时立即应用覆盖 ──────────────────
  const stored = takeOverrideFromURL() ?? readStoredOverride();
  if (stored && stored !== "auto") {
    name.value = normalize(stored);
    overridden.value = true;
    ready.value = true;
  }

  return {
    name,
    safeArea,
    safeAreaStyle,
    isMobile,
    ready,
    overridden,
    init,
    setOverride,
  };
});
