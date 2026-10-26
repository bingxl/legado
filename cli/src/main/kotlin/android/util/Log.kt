@file:Suppress("unused", "ClassName")

package android.util

/**
 * JVM 侧替身：legado 的调试日志走 android.util.Log，桌面环境转发到 stdout。
 */
object Log {

    const val VERBOSE = 2
    const val DEBUG = 3
    const val INFO = 4
    const val WARN = 5
    const val ERROR = 6

    @JvmStatic
    fun v(tag: String?, msg: String?): Int = print("V", tag, msg, null)

    @JvmStatic
    fun d(tag: String?, msg: String?): Int = print("D", tag, msg, null)

    @JvmStatic
    fun i(tag: String?, msg: String?): Int = print("I", tag, msg, null)

    @JvmStatic
    fun w(tag: String?, msg: String?): Int = print("W", tag, msg, null)

    @JvmStatic
    fun e(tag: String?, msg: String?): Int = print("E", tag, msg, null)

    @JvmStatic
    fun e(tag: String?, msg: String?, tr: Throwable?): Int = print("E", tag, msg, tr)

    @JvmStatic
    fun getStackTraceString(tr: Throwable?): String = tr?.stackTraceToString() ?: ""

    /**
     * 桌面端日志开关，由 CLI 的 --verbose 控制
     */
    var enabled: Boolean = false

    private fun print(level: String, tag: String?, msg: String?, tr: Throwable?): Int {
        if (!enabled) return 0
        println("$level/$tag: $msg")
        tr?.printStackTrace()
        return 0
    }
}
