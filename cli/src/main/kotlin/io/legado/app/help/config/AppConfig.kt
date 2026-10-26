package io.legado.app.help.config

import io.legado.app.constant.AppConst

/**
 * 运行时配置。App 里来自 SharedPreferences，桌面端来自命令行 + 配置文件。
 */
object AppConfig {

    var threadCount: Int = 8

    var userAgent: String = AppConst.DEFAULT_USER_AGENT

    var tocCountWords: Boolean = true

    /** 是否启用 Cronet 网络栈，桌面端恒为 false（统一走 OkHttp） */
    val isCronet: Boolean = false

    /** 代理地址，形如 http://127.0.0.1:7890，空表示直连 */
    var proxy: String? = null

    /** 请求超时（秒） */
    var timeoutSeconds: Long = 60

    /** 并发限制：同一书源的请求间隔由 concurrentRate 控制，这里是全局兜底 */
    var maxConcurrentPerSource: Int = 3
}
