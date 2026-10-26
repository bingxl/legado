package io.legado.app.utils

import java.io.File
import java.nio.charset.Charset

/**
 * 编码探测：App 用 icu4j 全量探测，桌面端做够用的近似实现
 * （HTML meta/charset 声明 → UTF-8 合法性 → GBK 兜底），
 * 覆盖中文站点 99% 的场景。
 */
@Suppress("unused")
object EncodingDetect {

    private val metaCharsetRegex = Regex(
        """charset\s*=\s*["']?\s*([a-zA-Z0-9_\-]+)""",
        RegexOption.IGNORE_CASE
    )

    fun getEncode(file: File): String = getEncode(file.readBytes())

    fun getEncode(bytes: ByteArray): String {
        val head = String(bytes, 0, minOf(bytes.size, 4096), Charsets.ISO_8859_1)
        metaCharsetRegex.find(head)?.groupValues?.get(1)?.let { name ->
            normalize(name)?.let { return it }
        }
        return if (isValidUtf8(bytes)) "UTF-8" else "GBK"
    }

    fun getHtmlEncode(bytes: ByteArray): String = getEncode(bytes)

    private fun normalize(name: String): String? = when (name.lowercase()) {
        "utf8", "utf-8" -> "UTF-8"
        "gb2312", "gbk", "gb18030" -> "GB18030"
        "big5" -> "Big5"
        "iso-8859-1", "latin1" -> "ISO-8859-1"
        else -> runCatching { Charset.forName(name).name() }.getOrNull()
    }

    private fun isValidUtf8(bytes: ByteArray): Boolean {
        var i = 0
        while (i < bytes.size) {
            val b = bytes[i].toInt() and 0xFF
            val extra = when {
                b < 0x80 -> 0
                b shr 5 == 0b110 -> 1
                b shr 4 == 0b1110 -> 2
                b shr 3 == 0b11110 -> 3
                else -> return false
            }
            if (i + extra >= bytes.size) return false
            repeat(extra) {
                val nb = bytes[i + 1 + it].toInt() and 0xFF
                if (nb shr 6 != 0b10) return false
            }
            i += extra + 1
        }
        return true
    }
}
