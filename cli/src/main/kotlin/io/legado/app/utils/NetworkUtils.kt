package io.legado.app.utils

import io.legado.app.constant.AppLog
import okhttp3.internal.publicsuffix.PublicSuffixDatabase
import java.net.URL
import java.util.BitSet

/**
 * 网络工具：只保留规则引擎用到的部分，语义与 App 完全一致
 * （encodedQuery/encodedForm 的保留字符表直接照搬，否则 URL 会被重复编码）。
 */
@Suppress("unused")
object NetworkUtils {

    private val notNeedEncodingQuery: BitSet by lazy {
        val bitSet = BitSet(256)
        for (i in 'a'.code..'z'.code) bitSet.set(i)
        for (i in 'A'.code..'Z'.code) bitSet.set(i)
        for (i in '0'.code..'9'.code) bitSet.set(i)
        for (char in "!$&()*+,-./:;=?@[\\]^_`{|}~") bitSet.set(char.code)
        bitSet
    }

    private val notNeedEncodingForm: BitSet by lazy {
        val bitSet = BitSet(256)
        for (i in 'a'.code..'z'.code) bitSet.set(i)
        for (i in 'A'.code..'Z'.code) bitSet.set(i)
        for (i in '0'.code..'9'.code) bitSet.set(i)
        for (char in "*-._") bitSet.set(char.code)
        bitSet
    }

    /**
     * 是否已经是合法的 urlEncode 结果（query）
     */
    fun encodedQuery(str: String): Boolean = isEncoded(str, notNeedEncodingQuery)

    /**
     * 是否已经是合法的 urlEncode 结果（form）
     */
    fun encodedForm(str: String): Boolean = isEncoded(str, notNeedEncodingForm)

    private fun isEncoded(str: String, notNeedEncoding: BitSet): Boolean {
        var i = 0
        while (i < str.length) {
            val c = str[i]
            if (c.code < 256 && notNeedEncoding.get(c.code)) {
                i++
                continue
            }
            if (c == '%' && i + 2 < str.length) {
                val c1 = str[++i]
                val c2 = str[++i]
                if (isDigit16Char(c1) && isDigit16Char(c2)) {
                    i++
                    continue
                }
            }
            return false
        }
        return true
    }

    private fun isDigit16Char(c: Char): Boolean =
        c in '0'..'9' || c in 'A'..'F' || c in 'a'..'f'

    fun getAbsoluteURL(baseURL: String?, relativePath: String): String {
        if (baseURL.isNullOrEmpty()) return relativePath.trim()
        val absoluteUrl = try {
            URL(baseURL.substringBefore(","))
        } catch (e: Exception) {
            e.printOnDebug()
            null
        }
        return getAbsoluteURL(absoluteUrl, relativePath)
    }

    fun getAbsoluteURL(baseURL: URL?, relativePath: String): String {
        val relativePathTrim = relativePath.trim()
        if (baseURL == null) return relativePathTrim
        if (relativePathTrim.isAbsUrl()) return relativePathTrim
        if (relativePathTrim.isDataUrl()) return relativePathTrim
        if (relativePathTrim.startsWith("javascript")) return ""
        return try {
            URL(baseURL, relativePath).toString()
        } catch (e: Exception) {
            AppLog.put("网址拼接出错\n${e.localizedMessage}", e)
            relativePath
        }
    }

    fun getBaseUrl(url: String?): String? {
        url ?: return null
        if (url.startsWith("http://", true) || url.startsWith("https://", true)) {
            val index = url.indexOf("/", 9)
            return if (index == -1) url else url.substring(0, index)
        }
        return null
    }

    fun getSubDomain(url: String): String {
        val baseUrl = getBaseUrl(url) ?: return url
        return kotlin.runCatching {
            val host: String = URL(baseUrl).host
            if (isIPAddress(host)) return host
            PublicSuffixDatabase.get().getEffectiveTldPlusOne(host) ?: host
        }.getOrDefault(baseUrl)
    }

    private fun isIPAddress(host: String): Boolean {
        return host.matches(Regex("""\d{1,3}(\.\d{1,3}){3}""")) ||
            host.contains(":") || host.equals("localhost", true)
    }
}
