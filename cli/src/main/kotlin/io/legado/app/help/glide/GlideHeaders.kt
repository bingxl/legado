@file:Suppress("unused")

package io.legado.app.help.glide

/**
 * JVM 侧替身：Glide 的请求头载体，桌面端直接持有 Map。
 */
class GlideHeaders(val headerMap: Map<String, String>) {

    fun getHeaders(): Map<String, String> = headerMap
}
