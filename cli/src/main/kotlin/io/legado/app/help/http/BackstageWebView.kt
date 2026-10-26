@file:Suppress("unused")

package io.legado.app.help.http

/**
 * 后台 WebView：App 用它执行依赖浏览器环境的 JS（如某些加密脚本）。
 * 桌面端没有 WebView，调用即报错——对应书源应改用 @js: 或 java.ajax。
 */
class BackstageWebView(
    private val url: String? = null,
    private val html: String? = null,
    private val tag: String? = null,
    private val javaScript: String? = null,
    private val sourceRegex: String? = null,
    private val overrideUrlRegex: String? = null,
    private val headerMap: Map<String, String>? = null,
    private val delayTime: Long = 0
) {

    suspend fun getStrResponse(): StrResponse {
        throw io.legado.app.exception.NoStackTraceException(
            "书源使用了 WebView（${url ?: "html"}），桌面 CLI 不支持；请改用 @js: 方案"
        )
    }
}
