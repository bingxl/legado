package io.legado.app.model

import io.legado.app.constant.AppPattern

/**
 * 书源调试输出。App 里会把日志推给调试界面，
 * 桌面端直接打到 stderr（--verbose 时），方便对照规则执行过程。
 */
object Debug {

    var verbose: Boolean = false

    /** App 里由调试界面注册，CLI 不使用，但 BookList 会判空 */
    var callback: ((String) -> Unit)? = null

    private val timeFormat = java.text.SimpleDateFormat("[mm:ss.SSS]", java.util.Locale.getDefault())

    private val startTime = System.currentTimeMillis()

    @Synchronized
    fun log(
        sourceUrl: String?,
        msg: String = "",
        print: Boolean = true,
        isHtml: Boolean = false,
        showTime: Boolean = true,
        state: Int = 1
    ) {
        if (!verbose || !print) return
        val time = if (showTime) {
            timeFormat.format(System.currentTimeMillis() - startTime)
        } else {
            ""
        }
        val text = if (isHtml) msg.replace(AppPattern.rnRegex, " ") else msg
        val prefix = sourceUrl?.let { "[$it]" } ?: ""
        System.err.println("$time$prefix$text")
    }

    @Synchronized
    fun log(msg: String, print: Boolean = true) {
        log(null, msg, print)
    }
}
