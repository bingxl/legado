package io.legado.app.help.http

import io.legado.app.utils.NetworkUtils
import okhttp3.Cookie
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import okhttp3.Response
import org.jsoup.Connection

/**
 * Cookie 管理：与 App 的策略一致
 * - 持久 Cookie 存 CookieStore（落盘）
 * - 会话 Cookie 只存内存
 * - 请求时按 subDomain 合并
 */
object CookieManager {

    const val cookieJarHeader = "CookieJar"

    private val sessionCookieMap = HashMap<String, String>()

    fun saveResponse(response: Response) {
        saveCookiesFromHeaders(response.request.url, response.headers)
    }

    fun saveResponse(response: Connection.Response) {
        val url = response.url().toHttpUrlOrNull() ?: return
        val builder = Headers.Builder()
        response.multiHeaders().forEach { (k, v) -> v.forEach { builder.add(k, it) } }
        saveCookiesFromHeaders(url, builder.build())
    }

    private fun saveCookiesFromHeaders(url: HttpUrl, headers: Headers) {
        val domain = NetworkUtils.getSubDomain(url.toString())
        val cookies = Cookie.parseAll(url, headers)
        if (cookies.isEmpty()) return
        val sessionCookie = cookies.filter { !it.persistent }.joinToString("; ") {
            "${it.name}=${it.value}"
        }
        val cookieString = cookies.filter { it.persistent }.joinToString("; ") {
            "${it.name}=${it.value}"
        }
        if (sessionCookie.isNotEmpty()) {
            updateSessionCookie(domain, sessionCookie)
        }
        if (cookieString.isNotEmpty()) {
            CookieStore.setCookie(domain, cookieString)
        }
    }

    fun loadRequest(request: Request): Request {
        val url = request.url.toString()
        val domain = NetworkUtils.getSubDomain(url)
        val cookie = CookieStore.getCookie(domain)
        val requestCookie = request.header("Cookie")
        val newCookie = mergeCookies(requestCookie, cookie) ?: return request
        return try {
            request.newBuilder().header("Cookie", newCookie).build()
        } catch (e: Exception) {
            request
        }
    }

    fun getSessionCookie(domain: String): String? = sessionCookieMap[domain]

    private fun updateSessionCookie(domain: String, cookies: String) {
        val sessionCookie = getSessionCookie(domain)
        val ck = mergeCookies(sessionCookie, cookies) ?: return
        sessionCookieMap[domain] = ck
    }

    fun mergeCookies(vararg cookies: String?): String? {
        val cookieMap = mergeCookiesToMap(*cookies)
        if (cookieMap.isEmpty()) return null
        return cookieMap.entries.joinToString("; ") { "${it.key}=${it.value}" }
    }

    fun mergeCookiesToMap(vararg cookies: String?): MutableMap<String, String> {
        val cookieMap = LinkedHashMap<String, String>()
        cookies.filterNotNull().forEach { cookie ->
            cookie.split(";").forEach { pair ->
                val kv = pair.trim()
                if (kv.isEmpty()) return@forEach
                val index = kv.indexOf('=')
                if (index <= 0) return@forEach
                val key = kv.substring(0, index).trim()
                val value = kv.substring(index + 1).trim()
                if (key.isNotEmpty()) cookieMap[key] = value
            }
        }
        return cookieMap
    }

    fun removeCookie(url: String, key: String) {
        val domain = NetworkUtils.getSubDomain(url)
        val cookie = CookieStore.getCookie(domain) ?: return
        val map = mergeCookiesToMap(cookie)
        map.remove(key)
        if (map.isEmpty()) {
            CookieStore.removeCookie(domain)
        } else {
            CookieStore.replaceCookie(domain, mergeCookies(mapToString(map)) ?: "")
        }
    }

    private fun mapToString(map: Map<String, String>): String =
        map.entries.joinToString("; ") { "${it.key}=${it.value}" }
}
