package com.wails.app;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;
import android.util.Log;
import android.view.KeyEvent;

import androidx.annotation.Nullable;

import org.json.JSONObject;

/**
 * 听书前台服务：对齐原版 AudioPlayService 的「原生后台能力」。
 *
 * 音频本身仍由 WebView 的 HTMLAudioElement 播放（真实 URL 不下发、Range 由
 * /stream/ 代理处理），本服务不碰音频数据，只负责：
 *
 * <ul>
 *   <li>前台保活 + MediaStyle 通知（上一章 / 播放暂停 / 下一章）；</li>
 *   <li>平台 MediaSession：锁屏、蓝牙耳机、车机与有线线控的媒体键；</li>
 *   <li>音频焦点：被来电 / 导航抢占时暂停，拔耳机（AUDIO_BECOMING_NOISY）暂停；</li>
 *   <li>WakeLock / WifiLock：熄屏后 CPU 与 Wi-Fi 不掉线。</li>
 * </ul>
 *
 * 与前端的通道是两条单向事件，互不阻塞：
 * <pre>
 *   前端 audioPlayer ── wails.audioState(json) ──▶ update() 本服务
 *   本服务 / MediaSession ── wails.Events("audio:command") ──▶ 前端 audioPlayer
 * </pre>
 *
 * 系统媒体键不会被前端的 navigator.mediaSession 重复接管：前端探测到
 * wails.audioState 存在时会跳过自己的 action handler，交给这里独占。
 */
public class AudioPlayService extends Service {
    private static final String TAG = "AudioPlayService";
    private static final String CHANNEL_ID = "legado_audio";
    private static final int NOTIFICATION_ID = 0x51A7;
    private static final String SESSION_TAG = "LegadoAudio";

    public static final String ACTION_UPDATE = "com.wails.app.AUDIO_UPDATE";
    public static final String ACTION_COMMAND = "com.wails.app.AUDIO_COMMAND";
    public static final String ACTION_STOP = "com.wails.app.AUDIO_STOP";
    public static final String EXTRA_STATE = "state";
    public static final String EXTRA_ACTION = "action";
    public static final String EXTRA_VALUE = "value";
    public static final String EXTRA_REASON = "reason";

    /** 宿主事件名，与 internal/port/event.go 的 EventAudioCommand 一致。 */
    private static final String EVENT_COMMAND = "audio:command";

    /** 静态桥引用：JS 注入对象与 Service 之间的唯一连接，Activity 销毁时必须 detach。 */
    private static volatile WailsBridge sBridge;
    private static volatile boolean sPlaying;
    private static volatile boolean sRunning;
    private static final Handler MAIN = new Handler(Looper.getMainLooper());

    private MediaSession mediaSession;
    private AudioManager audioManager;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;
    private AudioFocusRequest focusRequest;
    private boolean focusGranted;
    private BroadcastReceiver noisyReceiver;
    private boolean noisyRegistered;
    private String stateJson = "{}";
    private boolean playing;

    // ── 静态入口 ──────────────────────────────────────────────

    /** MainActivity 创建 Go bridge 后注入；Service 用它把媒体键命令发回前端。 */
    public static void attachBridge(WailsBridge bridge) {
        sBridge = bridge;
    }

    /** 只清掉同一个 bridge，避免旧 Activity 的 detach 误伤新实例。 */
    public static void detachBridge(WailsBridge bridge) {
        if (sBridge == bridge) sBridge = null;
    }

    /** 播放中按返回键时由 MainActivity 查询：true 则 moveTaskToBack 而非 finish。 */
    public static boolean isPlaying() {
        return sPlaying;
    }

    /**
     * 前端上报播放态。必须在主线程调用（WailsJSBridge 已负责 post）。
     * idle 会停掉前台服务并释放所有锁；其余状态启动或更新通知与 MediaSession。
     */
    public static void update(Context ctx, String json) {
        if (ctx == null || json == null) return;
        final Context app = ctx.getApplicationContext();
        final JSONObject st;
        try {
            st = new JSONObject(json);
        } catch (Exception e) {
            Log.w(TAG, "audioState 不是合法 JSON", e);
            return;
        }
        final boolean nowPlaying = "playing".equals(st.optString("status"));
        final boolean idle = "idle".equals(st.optString("status"));
        sPlaying = nowPlaying;

        Intent intent = new Intent(app, AudioPlayService.class);
        if (idle) {
            intent.setAction(ACTION_STOP);
            // 停止时不需要前台启动权限，普通 stopService 即可。
            try {
                app.stopService(intent);
            } catch (Exception e) {
                Log.w(TAG, "stop audio service failed", e);
            }
            return;
        }
        intent.setAction(ACTION_UPDATE).putExtra(EXTRA_STATE, json);
        try {
            if (sRunning) {
                // 服务已在前台：普通 startService 只投递 onStartCommand，
                // 不会撞 Android 12+ 后台 startForegroundService 限制。
                app.startService(intent);
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                app.startForegroundService(intent);
            } else {
                app.startService(intent);
            }
        } catch (Exception e) {
            // 后台启动被拒时不能让播放中断：状态仍在前端，下次回前台会补上。
            Log.w(TAG, "start audio service failed", e);
        }
    }

    /** 把原生指令发进 Wails 事件总线，前端 audioPlayer 订阅后执行。 */
    public static void emitCommand(final String action, final double value, final String reason) {
        MAIN.post(() -> {
            WailsBridge b = sBridge;
            if (b == null) return;
            try {
                JSONObject payload = new JSONObject();
                payload.put("action", action);
                payload.put("value", value);
                payload.put("reason", reason);
                b.emitEvent(EVENT_COMMAND, payload.toString());
            } catch (Exception e) {
                Log.w(TAG, "emit audio:command failed", e);
            }
        });
    }

    // ── Service 生命周期 ──────────────────────────────────────

    @Override
    public void onCreate() {
        super.onCreate();
        sRunning = true;
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        createChannel();
        createSession();
        createLocks();
        registerNoisyReceiver();
        // 首次 startForegroundService 必须在 5 秒内 startForeground，
        // 先用一份最小通知占位，onStartCommand 会立刻换成真实状态。
        startAsForeground(buildNotification(new JSONObject()));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) return START_NOT_STICKY;
        String action = intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopPlayback();
            return START_NOT_STICKY;
        }
        if (ACTION_COMMAND.equals(action)) {
            emitCommand(
                    intent.getStringExtra(EXTRA_ACTION),
                    intent.getDoubleExtra(EXTRA_VALUE, 0),
                    intent.getStringExtra(EXTRA_REASON));
            return START_NOT_STICKY;
        }
        String json = intent.getStringExtra(EXTRA_STATE);
        stateJson = json == null ? "{}" : json;
        JSONObject st = parseState();
        playing = "playing".equals(st.optString("status"));
        updateSession(st);
        updateLocks();
        if (playing) requestFocus();
        startAsForeground(buildNotification(st));
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        sRunning = false;
        sPlaying = false;
        releaseLocks();
        abandonFocus();
        unregisterNoisyReceiver();
        if (mediaSession != null) {
            mediaSession.setActive(false);
            mediaSession.release();
            mediaSession = null;
        }
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void stopPlayback() {
        sPlaying = false;
        playing = false;
        // 立刻清标志：下一次播放必须用 startForegroundService 重新起服务。
        // 等 onDestroy 才清的话，紧接的一次 start 会退化成普通 startService，
        // 在 Android 12+ 后台场景下可能被拒，前台通知就再也不会出现。
        sRunning = false;
        stopForeground(true);
        stopSelf();
    }

    // ── 通知 ──────────────────────────────────────────────────

    private void createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (nm == null) return;
        NotificationChannel ch = new NotificationChannel(
                CHANNEL_ID, "听书播放", NotificationManager.IMPORTANCE_LOW);
        ch.setDescription("播放控制与后台保活");
        ch.setSound(null, null);
        ch.enableVibration(false);
        nm.createNotificationChannel(ch);
    }

    private void startAsForeground(Notification n) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, n,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            } else {
                startForeground(NOTIFICATION_ID, n);
            }
        } catch (Exception e) {
            Log.w(TAG, "startForeground failed", e);
        }
    }

    private Notification buildNotification(JSONObject st) {
        String book = st.optString("bookName", "");
        String chapter = st.optString("chapterTitle", "");
        String title = chapter.isEmpty() ? (book.isEmpty() ? "听书" : book) : chapter;
        String text = book.isEmpty() ? "正在听书" : book;

        int piFlags = pendingIntentFlags() | PendingIntent.FLAG_UPDATE_CURRENT;
        Intent launch = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent content = null;
        if (launch != null) {
            launch.setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            launch.putExtra("audio:fromNotification", true);
            content = PendingIntent.getActivity(this, 10, launch, piFlags);
        }

        Notification.Builder b = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        b.setSmallIcon(R.drawable.ic_stat_audio)
                .setContentTitle(title)
                .setContentText(text)
                .setContentIntent(content)
                .setOnlyAlertOnce(true)
                .setOngoing(playing)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .addAction(notificationAction(
                        android.R.drawable.ic_media_previous, "上一章", "prev"))
                .addAction(notificationAction(
                        playing ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play,
                        playing ? "暂停" : "播放", "toggle"))
                .addAction(notificationAction(
                        android.R.drawable.ic_media_next, "下一章", "next"));
        if (mediaSession != null) {
            b.setStyle(new Notification.MediaStyle()
                    .setMediaSession(mediaSession.getSessionToken())
                    .setShowActionsInCompactView(0, 1, 2));
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            b.setPriority(Notification.PRIORITY_LOW);
        }
        return b.build();
    }

    private Notification.Action notificationAction(int icon, String label, String command) {
        Intent i = new Intent(this, AudioPlayService.class)
                .setAction(ACTION_COMMAND)
                .putExtra(EXTRA_ACTION, command)
                .putExtra(EXTRA_REASON, "notification");
        PendingIntent pi = PendingIntent.getService(
                this, 20 + Math.abs(command.hashCode() % 100), i, pendingIntentFlags());
        // Builder(int, CharSequence, PendingIntent) 从 API 20 起可用，
        // 用系统内置媒体图标就不必再引入 androidx.media 依赖。
        return new Notification.Action.Builder(icon, label, pi).build();
    }

    private static int pendingIntentFlags() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
                ? PendingIntent.FLAG_IMMUTABLE : 0;
    }

    // ── MediaSession / 媒体键 ─────────────────────────────────

    private void createSession() {
        mediaSession = new MediaSession(this, SESSION_TAG);
        mediaSession.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        mediaSession.setCallback(new MediaSession.Callback() {
            @Override
            public void onPlay() {
                emitCommand("play", 0, "media_button");
            }

            @Override
            public void onPause() {
                emitCommand("pause", 0, "media_button");
            }

            @Override
            public void onStop() {
                emitCommand("stop", 0, "media_button");
            }

            @Override
            public void onSkipToNext() {
                emitCommand("next", 0, "media_button");
            }

            @Override
            public void onSkipToPrevious() {
                emitCommand("prev", 0, "media_button");
            }

            @Override
            public void onSeekTo(long pos) {
                emitCommand("seekto", pos, "media_button");
            }

            @Override
            public void onRewind() {
                emitCommand("seekbackward", 15, "media_button");
            }

            @Override
            public void onFastForward() {
                emitCommand("seekforward", 15, "media_button");
            }

            @Override
            public boolean onMediaButtonEvent(Intent mediaButtonIntent) {
                if (mediaButtonIntent == null) return false;
                KeyEvent ke = mediaButtonIntent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
                if (ke == null || ke.getAction() != KeyEvent.ACTION_DOWN) {
                    return super.onMediaButtonEvent(mediaButtonIntent);
                }
                switch (ke.getKeyCode()) {
                    case KeyEvent.KEYCODE_MEDIA_PLAY:
                        emitCommand("play", 0, "media_button");
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PAUSE:
                        emitCommand("pause", 0, "media_button");
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                    case KeyEvent.KEYCODE_HEADSETHOOK:
                        emitCommand("toggle", 0, "media_button");
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_NEXT:
                        emitCommand("next", 0, "media_button");
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                        emitCommand("prev", 0, "media_button");
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_STOP:
                        emitCommand("stop", 0, "media_button");
                        return true;
                    default:
                        return super.onMediaButtonEvent(mediaButtonIntent);
                }
            }
        });
        mediaSession.setActive(true);
    }

    private void updateSession(JSONObject st) {
        if (mediaSession == null) return;
        try {
            String book = st.optString("bookName", "");
            String chapter = st.optString("chapterTitle", "");
            long duration = st.optLong("durationMs", 0);
            MediaMetadata.Builder mb = new MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE,
                            chapter.isEmpty() ? book : chapter)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, book)
                    .putString(MediaMetadata.METADATA_KEY_ALBUM, book)
                    .putLong(MediaMetadata.METADATA_KEY_DURATION, Math.max(0, duration));
            mediaSession.setMetadata(mb.build());

            long actions = PlaybackState.ACTION_PLAY | PlaybackState.ACTION_PAUSE
                    | PlaybackState.ACTION_PLAY_PAUSE | PlaybackState.ACTION_STOP
                    | PlaybackState.ACTION_SKIP_TO_NEXT | PlaybackState.ACTION_SKIP_TO_PREVIOUS
                    | PlaybackState.ACTION_SEEK_TO | PlaybackState.ACTION_REWIND
                    | PlaybackState.ACTION_FAST_FORWARD;
            float rate = (float) st.optDouble("rate", 1.0);
            long position = Math.max(0, st.optLong("positionMs", 0));
            PlaybackState.Builder pb = new PlaybackState.Builder()
                    .setActions(actions)
                    .setState(playing ? PlaybackState.STATE_PLAYING : PlaybackState.STATE_PAUSED,
                            position, rate > 0 ? rate : 1.0f, SystemClock.elapsedRealtime());
            mediaSession.setPlaybackState(pb.build());
        } catch (Exception e) {
            Log.w(TAG, "update MediaSession failed", e);
        }
    }

    // ── 音频焦点 ──────────────────────────────────────────────

    private final AudioManager.OnAudioFocusChangeListener focusListener = change -> {
        switch (change) {
            case AudioManager.AUDIOFOCUS_LOSS:
            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT:
                // 来电、导航、另一个播放器抢占：立刻停，别和对方一起响。
                emitCommand("pause", 0, "audio_focus");
                break;
            case AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK:
                // 系统会自动 duck 本应用的媒体流，这里只留诊断事件，
                // 不改用户的音量偏好，避免恢复时把音量写错。
                emitCommand("duck", 0, "audio_focus");
                break;
            case AudioManager.AUDIOFOCUS_GAIN:
            default:
                break;
        }
    };

    @SuppressLint("NewApi")
    private void requestFocus() {
        if (audioManager == null || focusGranted) return;
        try {
            int result;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                AudioAttributes attrs = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build();
                focusRequest = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(attrs)
                        .setWillPauseWhenDucked(true)
                        .setOnAudioFocusChangeListener(focusListener, MAIN)
                        .build();
                result = audioManager.requestAudioFocus(focusRequest);
            } else {
                result = audioManager.requestAudioFocus(
                        focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
            }
            focusGranted = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED;
        } catch (Exception e) {
            Log.w(TAG, "requestAudioFocus failed", e);
        }
    }

    private void abandonFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) {
                audioManager.abandonAudioFocusRequest(focusRequest);
            } else {
                audioManager.abandonAudioFocus(focusListener);
            }
        } catch (Exception e) {
            Log.w(TAG, "abandonAudioFocus failed", e);
        }
        focusGranted = false;
        focusRequest = null;
    }

    // ── 拔耳机 / 断开蓝牙 ────────────────────────────────────

    private void registerNoisyReceiver() {
        if (noisyRegistered) return;
        noisyReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                if (AudioManager.ACTION_AUDIO_BECOMING_NOISY.equals(intent.getAction())) {
                    emitCommand("pause", 0, "noisy");
                }
            }
        };
        try {
            IntentFilter filter = new IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            } else {
                registerReceiver(noisyReceiver, filter);
            }
            noisyRegistered = true;
        } catch (Exception e) {
            Log.w(TAG, "register noisy receiver failed", e);
        }
    }

    private void unregisterNoisyReceiver() {
        if (!noisyRegistered || noisyReceiver == null) return;
        try {
            unregisterReceiver(noisyReceiver);
        } catch (Exception e) {
            Log.w(TAG, "unregister noisy receiver failed", e);
        }
        noisyRegistered = false;
        noisyReceiver = null;
    }

    // ── WakeLock / WifiLock ───────────────────────────────────

    @SuppressLint("WifiManagerLeak")
    private void createLocks() {
        try {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            if (pm != null) {
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "legado:audio");
                wakeLock.setReferenceCounted(false);
            }
        } catch (Exception e) {
            Log.w(TAG, "create WakeLock failed", e);
        }
        try {
            // 用 Application context，避免 WifiManager 在部分机型上持有 Activity。
            WifiManager wm = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
            if (wm != null) {
                wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "legado:audio");
                wifiLock.setReferenceCounted(false);
            }
        } catch (Exception e) {
            Log.w(TAG, "create WifiLock failed", e);
        }
    }

    private void updateLocks() {
        if (playing) {
            acquire(wakeLock);
            acquire(wifiLock);
        } else {
            // 暂停时释放 CPU / Wi-Fi 锁，前台服务本身继续保活进程与通知。
            release(wakeLock);
            release(wifiLock);
        }
    }

    private void releaseLocks() {
        release(wakeLock);
        release(wifiLock);
    }

    private static void acquire(Object lock) {
        try {
            if (lock instanceof PowerManager.WakeLock) {
                PowerManager.WakeLock wl = (PowerManager.WakeLock) lock;
                if (!wl.isHeld()) wl.acquire();
            } else if (lock instanceof WifiManager.WifiLock) {
                WifiManager.WifiLock wl = (WifiManager.WifiLock) lock;
                if (!wl.isHeld()) wl.acquire();
            }
        } catch (Exception e) {
            Log.w(TAG, "acquire lock failed", e);
        }
    }

    private static void release(Object lock) {
        try {
            if (lock instanceof PowerManager.WakeLock) {
                PowerManager.WakeLock wl = (PowerManager.WakeLock) lock;
                if (wl.isHeld()) wl.release();
            } else if (lock instanceof WifiManager.WifiLock) {
                WifiManager.WifiLock wl = (WifiManager.WifiLock) lock;
                if (wl.isHeld()) wl.release();
            }
        } catch (Exception e) {
            Log.w(TAG, "release lock failed", e);
        }
    }

    private JSONObject parseState() {
        try {
            return new JSONObject(stateJson);
        } catch (Exception e) {
            return new JSONObject();
        }
    }
}
