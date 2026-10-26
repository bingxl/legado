@file:Suppress("unused")

package androidx.media3.common

/**
 * JVM 侧替身：AnalyzeUrl 只为音频源暴露 getMediaItem()，
 * 桌面端不需要 ExoPlayer，这里只保留类型占位。
 */
class MediaItem private constructor(val uri: String?) {

    class Builder {
        private var uri: String? = null
        fun setUri(uri: String?): Builder = apply { this.uri = uri }
        fun build(): MediaItem = MediaItem(uri)
    }

    companion object {
        fun fromUri(uri: String?): MediaItem = MediaItem(uri)
    }
}
