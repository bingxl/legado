package io.legado.app.help.http

import io.legado.app.help.config.CliStorage
import io.legado.app.help.http.CookieManager.mergeCookiesToMap
import io.legado.app.utils.GSON
import io.legado.app.utils.NetworkUtils

/**
 * 持久 Cookie：App 里落 Room，桌面端存 JSON 文件，进程重启后仍在。
 */
object CookieStore {

    private val cookies = HashMap<String, String>()

    private val file by lazy { CliStorage.cacheFile("cookies.json") }

    private var loaded = false

    @Synchronized
    private fun load() {
        if (loaded) return
        loaded = true
        kotlin.runCatching {
            if (file.exists()) {
                val map = GSON.fromJson(file.readText(), HashMap::class.java) ?: return
                map.forEach { (k, v) -> cookies[k.toString()] = v.toString() }
            }
        }
    }

    @Synchronized
    private fun save() {
        kotlin.runCatching {
            file.parentFile?.mkdirs()
            file.writeText(GSON.toJson(cookies))
        }
    }

    fun setCookie(url: String, cookie: String?) {
        load()
        val domain = NetworkUtils.getSubDomain(url)
        if (cookie.isNullOrBlank()) {
            cookies.remove(domain)
        } else {
            cookies[domain] = cookie
        }
        save()
    }

    fun replaceCookie(url: String, cookie: String) {
        load()
        val domain = NetworkUtils.getSubDomain(url)
        cookies[domain] = cookie
        save()
    }

    fun getCookie(url: String): String {
        load()
        val domain = NetworkUtils.getSubDomain(url)
        return cookies[domain] ?: ""
    }

    fun getCookieNoSession(url: String): String {
        load()
        return cookies[NetworkUtils.getSubDomain(url)] ?: ""
    }

    fun getKey(url: String, key: String): String {
        load()
        val cookieMap = mergeCookiesToMap(getCookie(url))
        return cookieMap[key] ?: ""
    }

    fun removeCookie(url: String) {
        load()
        cookies.remove(NetworkUtils.getSubDomain(url))
        save()
    }

    fun clear() {
        cookies.clear()
        save()
    }

    fun all(): Map<String, String> {
        load()
        return cookies.toMap()
    }
}
