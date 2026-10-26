@file:Suppress("unused")

package com.bumptech.glide.load.model

/**
 * JVM 侧替身：Glide 的 GlideUrl 只是把 url + header 打包，
 * 桌面端图片下载直接读 headers，不需要 Glide。
 */
open class GlideUrl(val url: String, val headers: Any? = null) {
    override fun toString(): String = url
}
