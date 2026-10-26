package io.legado.app.constant

/**
 * 书源类型：0 文本 / 1 音频 / 2 图片 / 3 下载站
 */
@Suppress("ConstPropertyName", "unused")
object BookSourceType {

    const val default = 0
    const val audio = 1
    const val image = 2
    const val file = 3

    @Target(AnnotationTarget.VALUE_PARAMETER)
    @Retention(AnnotationRetention.SOURCE)
    annotation class Type
}
