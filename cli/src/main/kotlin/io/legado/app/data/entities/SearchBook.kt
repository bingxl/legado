package io.legado.app.data.entities

import io.legado.app.constant.BookType
import io.legado.app.utils.GSON
import io.legado.app.utils.fromJsonObject

data class SearchBook(
    override var bookUrl: String = "",
    var origin: String = "",
    var originName: String = "",
    var type: Int = BookType.text,
    override var name: String = "",
    override var author: String = "",
    override var kind: String? = null,
    var coverUrl: String? = null,
    var intro: String? = null,
    override var wordCount: String? = null,
    var latestChapterTitle: String? = null,
    var tocUrl: String = "",
    var time: Long = System.currentTimeMillis(),
    override var variable: String? = null,
    var originOrder: Int = 0,
    var chapterWordCountText: String? = null,
    var chapterWordCount: Int = -1,
    var respondTime: Int = -1
) : BaseBook, Comparable<SearchBook> {

    override var infoHtml: String? = null

    override var tocHtml: String? = null

    override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: HashMap()
    }

    val origins: LinkedHashSet<String> by lazy { linkedSetOf(origin) }

    fun addOrigin(origin: String) {
        origins.add(origin)
    }

    override fun equals(other: Any?) = other is SearchBook && other.bookUrl == bookUrl

    override fun hashCode() = bookUrl.hashCode()

    override fun compareTo(other: SearchBook): Int = other.originOrder - this.originOrder

    fun getDisplayLastChapterTitle(): String {
        latestChapterTitle?.let { if (it.isNotEmpty()) return it }
        return "无最新章节"
    }

    fun releaseHtmlData() {
        infoHtml = null
        tocHtml = null
    }

    fun primaryStr(): String = origin + bookUrl

    fun sameBookTypeLocal(bookType: Int): Boolean {
        return type and BookType.allBookTypeLocal == bookType and BookType.allBookTypeLocal
    }

    fun toBook() = Book(
        name = name,
        author = author,
        kind = kind,
        bookUrl = bookUrl,
        origin = origin,
        originName = originName,
        type = type,
        wordCount = wordCount,
        latestChapterTitle = latestChapterTitle,
        coverUrl = coverUrl,
        intro = intro,
        tocUrl = tocUrl,
        originOrder = originOrder,
        variable = variable
    ).apply {
        this.infoHtml = this@SearchBook.infoHtml
        this.tocHtml = this@SearchBook.tocHtml
    }
}
