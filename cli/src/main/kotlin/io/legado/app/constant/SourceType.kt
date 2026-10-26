package io.legado.app.constant

@Suppress("ConstPropertyName", "unused")
object SourceType {

    const val book = 0
    const val rss = 1

    @Target(AnnotationTarget.VALUE_PARAMETER)
    @Retention(AnnotationRetention.SOURCE)
    annotation class Type
}
