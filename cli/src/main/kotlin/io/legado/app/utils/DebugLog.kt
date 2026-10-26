package io.legado.app.utils

import android.util.Log

/**
 * 调试日志：与 App 同名，桌面端转发到 android.util.Log 的替身（--verbose 时输出）
 */
object DebugLog {

    private const val TAG = "DebugLog"

    fun d(msg: String) {
        Log.d(TAG, msg)
    }

    fun d(tag: String, msg: String) {
        Log.d(tag, msg)
    }

    @JvmStatic
    fun e(tag: String, msg: String, tr: Throwable? = null) {
        Log.e(tag, msg, tr)
    }

    @JvmStatic
    fun e(msg: String, tr: Throwable? = null) {
        Log.e(TAG, msg, tr)
    }
}
