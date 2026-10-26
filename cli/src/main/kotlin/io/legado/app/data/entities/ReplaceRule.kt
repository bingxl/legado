package io.legado.app.data.entities

/**
 * 替换规则（正文净化用）。CLI 默认不加载替换规则，
 * 保留这个最小结构是为了让 BookChapter.getDisplayTitle 等签名与 App 一致。
 */
data class ReplaceRule(
    var name: String = "",
    var pattern: String = "",
    var replacement: String = "",
    var isRegex: Boolean = false,
    var timeoutMillisecond: Long = 3000L,
    var isEnabled: Boolean = true
) {

    val regex: Regex by lazy { Regex(pattern) }

    fun getValidTimeoutMillisecond(): Long = if (timeoutMillisecond <= 0) 3000L else timeoutMillisecond
}
