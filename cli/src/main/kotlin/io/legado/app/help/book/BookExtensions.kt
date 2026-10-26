package io.legado.app.help.book

import io.legado.app.constant.AppPattern
import io.legado.app.constant.BookType
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.ReplaceRule

/**
 * 书籍扩展：与 App 同名同语义的精简版（去掉本地文件、导出、书架相关）
 */

val Book.isWebFile: Boolean
    get() = isType(BookType.webFile)

val Book.isUpError: Boolean
    get() = isType(BookType.updateError)

val Book.isLocal: Boolean
    get() = isType(BookType.local)

fun Book.isType(bookType: Int): Boolean = type and bookType > 0

fun Book.setType(vararg types: Int) {
    type = types.fold(0) { acc, i -> acc or i }
}

fun Book.addType(vararg types: Int) {
    types.forEach { type = type or it }
}

fun Book.removeType(vararg types: Int) {
    types.forEach { type = type and it.inv() }
}

fun Book.removeAllBookType() {
    type = 0
}

fun Book.simulatedTotalChapterNum(): Int = totalChapterNum

fun Book.releaseHtmlData() {
    infoHtml = null
    tocHtml = null
}

fun Book.primaryStr(): String = origin + bookUrl

fun Book.getFolderNameNoCache(): String {
    return AppPattern.fileNameRegex.replace(
        AppPattern.fileNameRegex2.replace(name, ""), "_"
    )
}

/**
 * 正文保存：App 写数据库/文件，CLI 暂存内存，由下载器取走落盘
 */
object BookHelp {

    private val contentCache = HashMap<String, String>()

    suspend fun saveContent(
        bookSource: BookSource,
        book: Book,
        bookChapter: BookChapter,
        content: String
    ) {
        contentCache[bookChapter.primaryStr()] = content
    }

    fun getContent(bookChapter: BookChapter): String? = contentCache[bookChapter.primaryStr()]

    fun clearContent() = contentCache.clear()

    fun formatBookName(name: String): String {
        return name.replace(AppPattern.nameRegex, "").trim { it <= ' ' }
    }

    fun formatBookAuthor(author: String): String {
        return author.replace(AppPattern.authorRegex, "").trim { it <= ' ' }
    }
}

/**
 * 正文处理：App 里负责替换规则、净化、分段；CLI 只保留标题替换规则入口
 */
class ContentProcessor(private val book: Book) {

    fun getTitleReplaceRules(): List<ReplaceRule> = emptyList()

    fun getContentReplaceRules(): List<ReplaceRule> = emptyList()

    companion object {
        fun get(book: Book): ContentProcessor = ContentProcessor(book)
    }
}
