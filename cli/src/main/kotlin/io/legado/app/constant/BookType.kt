package io.legado.app.constant

/**
 * 书籍类型位标记，与 App 取值一致（BookSourceType 与 BookType 是两套编码）。
 */
@Suppress("ConstPropertyName", "unused")
object BookType {

    const val text = 0b1000
    const val updateError = 0b10000
    const val audio = 0b100000
    const val image = 0b1000000
    const val webFile = 0b10000000
    const val local = 0b100000000
    const val archive = 0b1000000000
    const val notShelf = 0b100_0000_0000

    @Target(AnnotationTarget.VALUE_PARAMETER)
    @Retention(AnnotationRetention.SOURCE)
    annotation class Type

    const val allBookType = text or image or audio or webFile
    const val allBookTypeLocal = text or image or audio or webFile or local

    const val localTag = "loc_book"
    const val webDavTag = "webDav::"
}
