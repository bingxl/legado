package io.legado.app.data

import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook

/**
 * 数据库替身：CLI 不需要持久化全书，只需在进程内支撑引擎对
 * "下一章 URL / 目录列表 / 书源查询" 的读取。
 */
object appDb {

    val bookChapterDao = BookChapterDao()
    val bookSourceDao = BookSourceDao()
    val searchBookDao = SearchBookDao()
    val cookieDao = NoopDao()
    val cacheDao = NoopDao()

    class BookChapterDao {

        private val chapters = LinkedHashMap<String, MutableList<BookChapter>>()

        fun getChapterList(bookUrl: String): List<BookChapter> = chapters[bookUrl] ?: emptyList()

        fun getChapter(bookUrl: String, index: Int): BookChapter? =
            chapters[bookUrl]?.firstOrNull { it.index == index }

        fun update(bookChapter: BookChapter) {
            val list = chapters.getOrPut(bookChapter.bookUrl) { arrayListOf() }
            val i = list.indexOfFirst { it.url == bookChapter.url && it.index == bookChapter.index }
            if (i >= 0) list[i] = bookChapter else list.add(bookChapter)
        }

        fun insert(vararg items: BookChapter) {
            items.forEach { update(it) }
        }

        fun deleteByBook(bookUrl: String) {
            chapters.remove(bookUrl)
        }
    }

    class BookSourceDao {

        private val sources = LinkedHashMap<String, BookSource>()

        fun getBookSource(url: String): BookSource? = sources[url]

        fun getAll(): List<BookSource> = sources.values.toList()

        fun insert(vararg items: BookSource) {
            items.forEach { sources[it.bookSourceUrl] = it }
        }

        fun delete(item: BookSource) {
            sources.remove(item.bookSourceUrl)
        }
    }

    class SearchBookDao {
        private val books = LinkedHashMap<String, SearchBook>()

        fun insert(vararg items: SearchBook) {
            items.forEach { books[it.bookUrl] = it }
        }

        fun getAll(): List<SearchBook> = books.values.toList()
    }

    class NoopDao {
        fun insert(vararg any: Any) = Unit
        fun get(key: String): Any? = null
        fun delete(key: String) = Unit
        fun deleteOkHttp() = Unit
    }
}
