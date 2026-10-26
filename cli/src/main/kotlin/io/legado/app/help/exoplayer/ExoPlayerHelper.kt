@file:Suppress("unused")

package io.legado.app.help.exoplayer

import androidx.media3.common.MediaItem

/**
 * JVM 侧替身：音频源才用到的 MediaItem 构造，桌面端只保留占位。
 */
object ExoPlayerHelper {

    fun createMediaItem(url: String, headerMap: Map<String, String>): MediaItem {
        return MediaItem.fromUri(url)
    }
}
