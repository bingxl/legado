/**
 * 视口断点（JS 侧）。
 *
 * 与 styles/responsive.css 的三档断点一一对应。CSS 负责绝大多数布局，
 * 只有「确实要换 DOM 结构」的地方才用这里的响应式状态——比如窄屏把
 * el-table 换成卡片列表、把三栏编辑页改成单栏。
 *
 * 平台判定（stores/platform.ts）回答的是「跑在哪台设备上」，
 * 断点回答的是「当前窗口有多宽」，两者不要互相替代：
 * 桌面端把窗口缩到 412px 时，平台仍是 desktop，但布局必须走 compact。
 */
import { computed, onUnmounted, ref, type ComputedRef, type Ref } from "vue";

/** 断点数值的唯一来源；改这里必须同步改 responsive.css 的 @media 数值。 */
export const BREAKPOINTS = {
  /** <= compact 为手机档 */
  compact: 640,
  /** <= medium 为平板/窄窗口档，其余为桌面档 */
  medium: 1024,
} as const;

export type LayoutSize = "compact" | "medium" | "wide";

export interface BreakpointState {
  /** 当前视口宽度（响应式） */
  width: Ref<number>;
  /** 当前档位 */
  size: ComputedRef<LayoutSize>;
  isCompact: ComputedRef<boolean>;
  isMedium: ComputedRef<boolean>;
  isWide: ComputedRef<boolean>;
  /** 是否为紧凑布局（compact 或 medium，即不适合多栏的窗口） */
  isNarrow: ComputedRef<boolean>;
}

// 全应用共享一个 resize 监听，引用计数归零时解绑。
const viewportWidth = ref<number>(
  typeof window === "undefined" ? 1200 : window.innerWidth,
);
let subscribers = 0;

function onResize() {
  viewportWidth.value = window.innerWidth;
}

/**
 * 在组件 setup 里调用，组件卸载会自动解绑监听。
 * 典型用法：
 *   const { isCompact } = useBreakpoint();
 *   const useCards = computed(() => platform.isMobile || isCompact.value);
 */
export function useBreakpoint(): BreakpointState {
  if (subscribers++ === 0) {
    window.addEventListener("resize", onResize, { passive: true });
    window.addEventListener("orientationchange", onResize, { passive: true });
  }
  onUnmounted(() => {
    if (--subscribers === 0) {
      window.removeEventListener("resize", onResize);
      window.removeEventListener("orientationchange", onResize);
    }
  });

  const size = computed<LayoutSize>(() => {
    const w = viewportWidth.value;
    if (w <= BREAKPOINTS.compact) return "compact";
    if (w <= BREAKPOINTS.medium) return "medium";
    return "wide";
  });

  return {
    width: viewportWidth,
    size,
    isCompact: computed(() => size.value === "compact"),
    isMedium: computed(() => size.value === "medium"),
    isWide: computed(() => size.value === "wide"),
    isNarrow: computed(() => size.value !== "wide"),
  };
}
