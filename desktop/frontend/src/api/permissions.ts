/**
 * 安卓端运行时权限（存储 / 相机）。
 *
 * 为什么走 WebView 注入的 `window.wails` 而不是 Go 绑定层：
 * 权限必须由 Activity 发起（requestPermissions 是 Activity 的方法），
 * 而 Wails 的 `application.Android` 只暴露固定的若干个桥接方法，没有权限通道；
 * 新增桥接方法需要改 wails 模块的 JNI 胶水，代价远大于收益。
 * 因此 Java 侧在 WailsJSBridge 里挂了三个 @JavascriptInterface 方法，
 * 这里包一层给视图用——业务层（Go）依然不感知平台，符合「业务层零平台分支」的约定。
 *
 * 桌面端不存在这些方法（`permissionStatus` 不是函数），permissionAvailable()
 * 返回 false，调用方按「无需权限」处理。注意不能靠 `window.wails` 是否存在判定：
 * 桌面端同样有这个对象，只是没有权限方法。
 *
 * 状态含义：
 *   granted           已授权
 *   denied            未授权，可再次弹系统对话框
 *   blocked           被永久拒绝，只能跳系统设置页
 *   settings_required 安卓 11+ 的「所有文件访问」，需用户去设置页手动开
 *   unavailable       设备没有该硬件（无相机）
 */
export type PermissionKind = "storage" | "camera";

export type PermissionState =
  | "granted"
  | "denied"
  | "blocked"
  | "settings_required"
  | "unavailable";

export interface PermissionStatus {
  /** 安卓 API Level，用于解释「为什么 11 以上要跳设置页」。 */
  sdk: number;
  storage: PermissionState;
  camera: PermissionState;
  /** 是否已获得「所有文件访问」（安卓 11+ 才有意义）。 */
  allFiles: boolean;
}

/** Java 侧注入对象的权限子集。 */
interface AndroidPermissionBridge {
  permissionStatus(): string;
  requestPermission(kind: string): boolean;
  openPermissionSettings(kind: string): boolean;
}

/** 事件名，与 MainActivity 里 emitEvent 的字符串保持一致。 */
const PERMISSION_EVENT = "android:permission";

/** 取注入对象；方法不存在即视为当前平台不需要这套东西。 */
function bridge(): AndroidPermissionBridge | null {
  const wails = (window as unknown as { wails?: Partial<AndroidPermissionBridge> })
    .wails;
  if (!wails || typeof wails.permissionStatus !== "function") return null;
  return wails as AndroidPermissionBridge;
}

/** 当前平台是否需要（且能够）申请运行时权限。 */
export function permissionAvailable(): boolean {
  return bridge() !== null;
}

function normalizeState(raw: unknown): PermissionState {
  switch (raw) {
    case "granted":
    case "denied":
    case "blocked":
    case "settings_required":
    case "unavailable":
      return raw;
    // Java 侧新增了状态而前端还没跟上时，按「未授权」处理总比崩掉好。
    default:
      return "denied";
  }
}

/** 读取权限状态快照；非安卓端或解析失败返回 null。 */
export function permissionStatus(): PermissionStatus | null {
  const b = bridge();
  if (!b) return null;
  try {
    const raw = b.permissionStatus();
    if (!raw) return null;
    const v = JSON.parse(raw) as Record<string, unknown>;
    return {
      sdk: Number(v.sdk) || 0,
      storage: normalizeState(v.storage),
      camera: normalizeState(v.camera),
      allFiles: Boolean(v.allFiles),
    };
  } catch {
    return null;
  }
}

/**
 * 发起申请。返回 true 表示系统交互已弹出（结果异步回来）。
 *
 * 存储权限在安卓 11+ 会打开「所有文件访问」设置页，用户从设置页返回后
 * 由 onResume 复查状态并发事件；相机是普通系统对话框。
 */
export function requestPermission(kind: PermissionKind): boolean {
  const b = bridge();
  if (!b) return false;
  try {
    return b.requestPermission(kind) === true;
  } catch {
    return false;
  }
}

/** 跳系统设置页：被永久拒绝后的唯一出路。 */
export function openPermissionSettings(kind: PermissionKind): boolean {
  const b = bridge();
  if (!b) return false;
  try {
    return b.openPermissionSettings(kind) === true;
  } catch {
    return false;
  }
}

/** 订阅权限状态变化，返回取消订阅函数。 */
export function onPermissionChanged(
  handler: (payload: { kind: PermissionKind; state: PermissionState }) => void,
): () => void {
  // 与 api/events.ts 同一约定：必须用注入的运行时，不能用打包进来的 Events。
  const events = (window as unknown as {
    wails?: {
      Events?: {
        On: (
          name: string,
          cb: (e: { data: unknown }) => void,
        ) => () => void;
      };
    };
  }).wails?.Events;
  if (!events) return () => {};
  return events.On(PERMISSION_EVENT, (e) => {
    const data = (e?.data ?? {}) as Record<string, unknown>;
    if (data.kind !== "storage" && data.kind !== "camera") return;
    handler({
      kind: data.kind,
      state: normalizeState(data.state),
    });
  });
}

/** 状态文案，供界面直接展示。 */
export function permissionStateLabel(state: PermissionState): string {
  switch (state) {
    case "granted":
      return "已授权";
    case "blocked":
      return "已拒绝（需去系统设置）";
    case "settings_required":
      return "未开启（需去系统设置）";
    case "unavailable":
      return "设备不支持";
    default:
      return "未授权";
  }
}
