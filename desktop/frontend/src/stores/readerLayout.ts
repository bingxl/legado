/**
 * 阅读器视图状态：全屏（以及 M3 的分屏布局）。
 *
 * 为什么需要 store 而不是放在 ReaderView 里：
 * 全屏要隐藏**左侧栏**，而左侧栏在 App.vue（阅读器的父级外壳）里——
 * 父子之间没有 props 通道，路由 query 又会让"开个全屏"进历史栈。
 * store 是这里最薄的一根线，两端都只读同一个布尔值。
 *
 * 与 platform store 的关系：平台判定仍然只信后端（`SystemAPI.Platform`），
 * 本 store 只回答"阅读器现在要不要沉浸"。`immersive` 把两端收敛成同一个表达式——
 * 移动端恒真（沉浸由栏位开关控制），桌面端由全屏态驱动。
 */
import { defineStore } from "pinia";
import { computed, ref } from "vue";

import { systemApi } from "@/api/system";
import { usePlatformStore } from "@/stores/platform";

/**
 * 对账去抖：全屏切换会连发多次 resize（窗口动画），
 * 等尺寸稳定后再查一次后端，避免每次 resize 都打一次绑定调用。
 */
const SYNC_DEBOUNCE_MS = 150;

export const useReaderLayoutStore = defineStore("readerLayout", () => {
  const platform = usePlatformStore();

  /** 桌面端主窗口是否全屏。安卓端恒 false（那边没有窗口层）。 */
  const fullscreen = ref(false);

  /**
   * 正在切换中。
   * 全屏是有动画的异步操作，连点两下会把窗口点成"切了又切"的中间态，
   * 期间直接忽略新的请求。
   */
  let switching = false;

  /** 沉浸：移动端恒真；桌面端由全屏态驱动。 */
  const immersive = computed(() => platform.isMobile || fullscreen.value);

  /**
   * 设置全屏。`force` 用于离场清理——即使正在切换也要把状态压回去。
   */
  async function setFullscreen(on: boolean, force = false) {
    if (!force && (switching || on === fullscreen.value)) return;
    // 安卓没有窗口层：本地开关照样生效，但只影响栏位（就是它的沉浸阅读）。
    // 走绑定会拿到 false 把状态打回去，这里直接本地处理。
    if (platform.isMobile) {
      fullscreen.value = on;
      return;
    }
    switching = true;
    try {
      fullscreen.value = await systemApi.setFullscreen(on);
    } catch {
      // 绑定不可用（单测 / 非 Wails 环境）时只改本地状态：
      // 栏位收起仍然是有意义的行为，不该因为窗口切不动就整块失效。
      fullscreen.value = on;
    } finally {
      switching = false;
    }
  }

  /** 切换全屏。 */
  async function toggle() {
    await setFullscreen(!fullscreen.value);
  }

  /** 退出全屏（离场、Esc）。 */
  async function exit() {
    await setFullscreen(false);
  }

  /**
   * 与后端对账。
   *
   * 用户可以用系统快捷键退出全屏（Win+↓、mac 绿灯按钮），那条路不经过
   * 我们的按钮，前端只能主动查。全屏切换**必然伴随窗口 resize**，
   * 所以挂在 resize 上比订阅窗口事件更可靠，也少一条不可验证的依赖。
   */
  async function sync() {
    if (platform.isMobile) return;
    try {
      const actual = await systemApi.isFullscreen();
      if (actual !== fullscreen.value) fullscreen.value = actual;
    } catch {
      // 查不到就保持现状，不能因为一次探测失败把用户弹出全屏
    }
  }

  let timer: number | null = null;
  function scheduleSync() {
    if (timer !== null) window.clearTimeout(timer);
    timer = window.setTimeout(() => {
      timer = null;
      void sync();
    }, SYNC_DEBOUNCE_MS);
  }

  /** 开始监听窗口尺寸变化（阅读器挂载时调用）。 */
  function attach() {
    window.addEventListener("resize", scheduleSync);
    window.addEventListener("focus", scheduleSync);
  }

  /** 停止监听。 */
  function detach() {
    window.removeEventListener("resize", scheduleSync);
    window.removeEventListener("focus", scheduleSync);
    if (timer !== null) {
      window.clearTimeout(timer);
      timer = null;
    }
  }

  return {
    fullscreen,
    immersive,
    setFullscreen,
    toggle,
    exit,
    sync,
    attach,
    detach,
  };
});
