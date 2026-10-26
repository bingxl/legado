package android.text

/**
 * JVM 侧替身：legado 的解析器只用到 TextUtils.join，
 * 桌面环境下用 kotlin 标准库等价实现，行为保持一致。
 */
object TextUtils {

    @JvmStatic
    fun join(delimiter: CharSequence, tokens: Iterable<*>): String {
        val sb = StringBuilder()
        var first = true
        for (token in tokens) {
            if (!first) sb.append(delimiter)
            sb.append(token)
            first = false
        }
        return sb.toString()
    }

    @JvmStatic
    fun isEmpty(str: CharSequence?): Boolean = str == null || str.isEmpty()

    @JvmStatic
    fun equals(a: CharSequence?, b: CharSequence?): Boolean = a?.toString() == b?.toString()
}
