package com.wails.app;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONObject;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * 安卓运行时权限的统一出口（存储 / 相机）。
 *
 * 为什么集中在一个类里：同一套「申请」要服务三个入口——启动引导弹窗、
 * 「我的 → 权限」的手动授权、以及相机 / 手电筒 / 网页 getUserMedia 的按需触发。
 * 三处对「已授权 / 被拒绝 / 永久拒绝 / 需去系统设置」的判定必须一致，
 * 否则会出现「设置页显示已授权，但拍照仍被拒」这种自相矛盾的状态。
 *
 * 存储权限分档（最容易写错的地方）：
 *   - API <= 22：危险权限安装即授予，恒为 granted；
 *   - API 23~29：READ_EXTERNAL_STORAGE（<=28 另有 WRITE）运行时申请。
 *     注意 targetSdk >= 29 起受分区存储约束，安卓 10 上该权限只覆盖媒体文件，
 *     读任意 txt/epub 仍要靠系统文件选择器（SAF）——这是系统限制，不是 bug；
 *   - API >= 30：READ_EXTERNAL_STORAGE 已不再授予读全盘的能力，读
 *     /storage/emulated/0 下任意书籍只能用「所有文件访问」
 *     （MANAGE_EXTERNAL_STORAGE）。它不是运行时权限，只能跳系统设置页让用户
 *     手动打开，且返回应用时没有回调——所以状态必须在 onResume 复查。
 *
 * 未授权时的降级路径：系统文件选择器（SAF）始终可用，选中的文件会被复制到
 * 应用私有目录，导入书籍/书源不依赖本类的任何权限。
 *
 * 状态取值（同时回给 JS，前端直接展示）：
 *   granted           已授权
 *   denied            未授权，可以再次弹系统对话框
 *   blocked           被永久拒绝（勾了「不再询问」），只能去应用设置页
 *   settings_required 需要用户去系统设置页手动打开「所有文件访问」（仅存储，API 30+）
 *   unavailable       设备没有该硬件（无相机）
 */
public final class AndroidPermissions {
    private static final String TAG = "WailsPermissions";

    public static final String KIND_STORAGE = "storage";
    public static final String KIND_CAMERA = "camera";

    public static final String STATE_GRANTED = "granted";
    public static final String STATE_DENIED = "denied";
    public static final String STATE_BLOCKED = "blocked";
    public static final String STATE_SETTINGS_REQUIRED = "settings_required";
    public static final String STATE_UNAVAILABLE = "unavailable";

    /** 相机权限的 requestCode。 */
    public static final int REQ_CAMERA = 7010;
    /** 存储权限的 requestCode（API <= 29 的运行时申请）。 */
    public static final int REQ_STORAGE = 7011;

    private static final String PREFS = "legado_permissions";
    private static final String KEY_PROMPTED = "storage_prompted_once";
    private static final String KEY_ASKED_PREFIX = "asked_";

    /**
     * 状态变化回调。由 MainActivity 注入，转成 "android:permission" 事件推给前端。
     * 只在状态**真的变化**时触发，避免 onResume 每次都刷一条。
     */
    public interface Listener {
        void onPermissionChanged(String kind, String state);
    }

    private final Activity activity;
    private final Listener listener;
    private final SharedPreferences prefs;
    /** 上一次对外公布的状态，用于做变化检测（首次为 null，表示还没公布过）。 */
    private final Map<String, String> lastStates = new LinkedHashMap<>();

    public AndroidPermissions(Activity activity, Listener listener) {
        this.activity = activity;
        this.listener = listener;
        this.prefs = activity.getSharedPreferences(PREFS, Activity.MODE_PRIVATE);
    }

    // ── 状态查询 ────────────────────────────────────────────────

    /** 存储权限状态，见类注释里的分档说明。 */
    public String storageState() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager() ? STATE_GRANTED : STATE_SETTINGS_REQUIRED;
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return STATE_GRANTED; // 安装时授予
        }
        if (granted(Manifest.permission.READ_EXTERNAL_STORAGE)) {
            return STATE_GRANTED;
        }
        return blocked(KIND_STORAGE, Manifest.permission.READ_EXTERNAL_STORAGE)
                ? STATE_BLOCKED : STATE_DENIED;
    }

    /** 相机权限状态。设备无相机时返回 unavailable，调用方据此隐藏入口。 */
    public String cameraState() {
        if (!activity.getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            return STATE_UNAVAILABLE;
        }
        if (granted(Manifest.permission.CAMERA)) {
            return STATE_GRANTED;
        }
        return blocked(KIND_CAMERA, Manifest.permission.CAMERA) ? STATE_BLOCKED : STATE_DENIED;
    }

    public String state(String kind) {
        if (KIND_STORAGE.equals(kind)) return storageState();
        if (KIND_CAMERA.equals(kind)) return cameraState();
        return STATE_UNAVAILABLE;
    }

    public boolean isStorageGranted() {
        return STATE_GRANTED.equals(storageState());
    }

    public boolean isCameraGranted() {
        return STATE_GRANTED.equals(cameraState());
    }

    /**
     * 权限状态快照（JSON），给 JS 的 permissionStatus() 用。
     * 顺带带上 sdk 与 allFiles，前端可以据此解释「为什么安卓 11 以上要跳设置页」。
     */
    public String statusJson() {
        try {
            JSONObject o = new JSONObject();
            o.put("sdk", Build.VERSION.SDK_INT);
            o.put("storage", storageState());
            o.put("camera", cameraState());
            o.put("allFiles", Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
                    && Environment.isExternalStorageManager());
            return o.toString();
        } catch (Exception e) {
            Log.w(TAG, "statusJson failed", e);
            return "{}";
        }
    }

    // ── 申请 ────────────────────────────────────────────────────

    /**
     * 申请权限。返回 true 表示确实发起了系统交互（对话框或设置页）；
     * false 表示无需申请（已授权 / 无该硬件 / 系统不允许）。
     *
     * 调用方不要假设返回 true 就一定拿到权限，结果经 onRequestPermissionsResult
     * 或 onResume（设置页返回）异步回来。
     */
    public boolean request(String kind) {
        String now = state(kind);
        if (STATE_GRANTED.equals(now) || STATE_UNAVAILABLE.equals(now)) {
            return false;
        }
        markAsked(kind);
        if (KIND_STORAGE.equals(kind) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return openAllFilesSettings();
        }
        String[] perms = manifestPermissions(kind);
        if (perms.length == 0) {
            return false;
        }
        try {
            activity.requestPermissions(perms, requestCode(kind));
            return true;
        } catch (Exception e) {
            Log.e(TAG, "requestPermissions failed: " + kind, e);
            return false;
        }
    }

    /**
     * 打开系统设置页：被永久拒绝后唯一的出路。
     * 存储（API 30+）直接跳「所有文件访问」，相机跳应用详情页。
     */
    public boolean openSettings(String kind) {
        if (KIND_STORAGE.equals(kind) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return openAllFilesSettings();
        }
        try {
            Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + activity.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(i);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "openAppSettings failed", e);
            return false;
        }
    }

    /**
     * 处理权限申请结果。返回 true 表示该 requestCode 归本类处理，
     * 调用方无需再往 Go 侧转发。
     */
    public boolean onRequestPermissionsResult(int requestCode, int[] grantResults) {
        String kind = null;
        if (requestCode == REQ_CAMERA) kind = KIND_CAMERA;
        else if (requestCode == REQ_STORAGE) kind = KIND_STORAGE;
        if (kind == null) return false;
        publish(kind, state(kind));
        return true;
    }

    // ── 启动引导 ────────────────────────────────────────────────

    /**
     * 是否该弹一次「需要存储权限」的说明弹窗。
     *
     * 只在首次启动且未授权时为 true：重复弹会变成骚扰，用户拒绝后
     * 依然能在「我的 → 权限」里手动开，不需要每次启动都拦一道。
     */
    public boolean shouldPromptStorageOnce() {
        return !isStorageGranted() && !prefs.getBoolean(KEY_PROMPTED, false);
    }

    /** 记下已经引导过（无论用户点「去授权」还是「暂不」）。 */
    public void markStoragePrompted() {
        prefs.edit().putBoolean(KEY_PROMPTED, true).apply();
    }

    // ── onResume 复查 ───────────────────────────────────────────

    /**
     * 复查并对外发布状态变化。
     *
     * 必须由 onResume 调用：从「所有文件访问」设置页返回是拿不到任何回调的，
     * 只有回到前台时重读状态才知道用户到底开没开。
     */
    public void refresh() {
        publish(KIND_STORAGE, storageState());
        publish(KIND_CAMERA, cameraState());
    }

    // ── 内部 ────────────────────────────────────────────────────

    /** 状态有变化才通知；首次只记录不外发（前端靠 statusJson 拉初值）。 */
    private void publish(String kind, String state) {
        String before = lastStates.put(kind, state);
        if (before == null || before.equals(state)) {
            return;
        }
        if (listener != null) {
            listener.onPermissionChanged(kind, state);
        }
    }

    private boolean granted(String permission) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return activity.getPackageManager()
                    .checkPermission(permission, activity.getPackageName())
                    == PackageManager.PERMISSION_GRANTED;
        }
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }

    /**
     * 是否已被永久拒绝。
     *
     * shouldShowRequestPermissionRationale 在「从未申请过」和「永久拒绝」两种
     * 情况下都返回 false，必须靠自己记的 asked 标记区分——否则首次启动就会被
     * 误判成 blocked，直接把用户甩到设置页。
     */
    private boolean blocked(String kind, String permission) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false;
        if (!prefs.getBoolean(KEY_ASKED_PREFIX + kind, false)) return false;
        try {
            return !activity.shouldShowRequestPermissionRationale(permission);
        } catch (Exception e) {
            return false;
        }
    }

    private void markAsked(String kind) {
        prefs.edit().putBoolean(KEY_ASKED_PREFIX + kind, true).apply();
    }

    private int requestCode(String kind) {
        return KIND_CAMERA.equals(kind) ? REQ_CAMERA : REQ_STORAGE;
    }

    /** 需要向系统申请的清单。API 30+ 的存储在 store 里没有运行时权限可申请。 */
    private String[] manifestPermissions(String kind) {
        if (KIND_CAMERA.equals(kind)) {
            return new String[]{Manifest.permission.CAMERA};
        }
        if (KIND_STORAGE.equals(kind)) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return new String[0]; // 走「所有文件访问」设置页
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                return new String[]{Manifest.permission.READ_EXTERNAL_STORAGE};
            }
            return new String[]{
                    Manifest.permission.READ_EXTERNAL_STORAGE,
                    Manifest.permission.WRITE_EXTERNAL_STORAGE};
        }
        return new String[0];
    }

    /** 打开「所有文件访问」页；个别 ROM 没有应用级入口时退回总开关页。 */
    private boolean openAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false;
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:" + activity.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(i);
            return true;
        } catch (Exception e) {
            Log.w(TAG, "app all-files settings unavailable, falling back to global page", e);
        }
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity.startActivity(i);
            return true;
        } catch (Exception e) {
            Log.e(TAG, "all-files settings unavailable", e);
            return false;
        }
    }
}
