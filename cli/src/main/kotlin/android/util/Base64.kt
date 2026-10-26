@file:Suppress("unused", "ClassName")

package android.util

import java.util.Base64 as JBase64

/**
 * JVM 侧替身：legado 的 AnalyzeUrl / EncoderUtils 使用 android.util.Base64，
 * 桌面环境用 java.util.Base64 实现同等语义（含 flag 兼容）。
 */
object Base64 {

    const val DEFAULT: Int = 0
    const val NO_PADDING: Int = 1
    const val NO_WRAP: Int = 2
    const val CRLF: Int = 4
    const val URL_SAFE: Int = 8
    const val NO_CLOSE: Int = 16

    @JvmStatic
    fun encodeToString(input: ByteArray, flags: Int): String {
        val encoder = when {
            flags and URL_SAFE != 0 -> JBase64.getUrlEncoder()
            else -> JBase64.getEncoder()
        }.let { if (flags and NO_PADDING != 0) it.withoutPadding() else it }
        return encoder.encodeToString(input)
    }

    @JvmStatic
    fun encode(input: ByteArray, flags: Int): ByteArray =
        encodeToString(input, flags).toByteArray(Charsets.ISO_8859_1)

    @JvmStatic
    fun decode(str: String, flags: Int): ByteArray {
        val normalized = str.replace("\r", "").replace("\n", "")
        val decoder = when {
            flags and URL_SAFE != 0 -> JBase64.getUrlDecoder()
            else -> JBase64.getMimeDecoder()
        }
        return decoder.decode(normalized)
    }

    @JvmStatic
    fun decode(input: ByteArray, flags: Int): ByteArray = decode(String(input), flags)
}
