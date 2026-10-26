package io.legado.app.constant

/**
 * 应用内错误日志。桌面端只保留内存环形缓冲 + 可选输出，
 * 不依赖 Toast / SharedPreferences。
 */
object AppLog {

    private val mLogs = arrayListOf<Triple<Long, String, Throwable?>>()

    val logs get() = mLogs.toList()

    /** 是否把错误直接打印到控制台（--verbose 时打开） */
    var printToConsole: Boolean = false

    @Synchronized
    fun put(message: String?, throwable: Throwable? = null, toast: Boolean = false) {
        message ?: return
        if (mLogs.size > 100) mLogs.removeAt(mLogs.lastIndex)
        mLogs.add(0, Triple(System.currentTimeMillis(), message, throwable))
        if (printToConsole) {
            System.err.println("[AppLog] $message")
            throwable?.printStackTrace()
        }
    }

    @Synchronized
    fun putNotSave(message: String?, throwable: Throwable? = null, toast: Boolean = false) {
        put(message, throwable, toast)
    }
}
