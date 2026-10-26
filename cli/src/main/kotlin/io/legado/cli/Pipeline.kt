package io.legado.cli

import io.legado.app.constant.BookSourceType
import io.legado.app.constant.BookType
import io.legado.app.data.appDb
import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.SearchBook
import io.legado.app.help.source.getBookType
import io.legado.app.model.webBook.WebBook
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File

/**
 * 书源流水线：搜索 → 详情 → 目录 → 正文。
 *
 * 这里只做调度与结果整理，真正的规则解析全部交给 app 模块里的
 * WebBook / AnalyzeUrl / AnalyzeRule 原码执行。
 */
object Pipeline {

    // ---------------------------------------------------------------- 搜索

    data class SearchHit(val source: BookSource, val book: SearchBook, val error: String? = null)

    /**
     * 并发搜索多个书源，单源失败不影响其它源。
     */
    suspend fun search(
        keyword: String,
        sources: List<BookSource>,
        page: Int = 1,
        onSourceDone: ((BookSource, Int, String?) -> Unit)? = null
    ): List<SearchHit> = coroutineScope {
        val semaphore = Semaphore(Cli.jobs)
        val jobs = sources.map { source ->
            async {
                semaphore.withPermit {
                    val result = runCatching {
                        WebBook.searchBookAwait(source, keyword, page)
                    }
                    result.onSuccess { list ->
                        onSourceDone?.invoke(source, list.size, null)
                    }.onFailure {
                        onSourceDone?.invoke(source, 0, it.message ?: it.javaClass.simpleName)
                    }
                    if (result.isSuccess) {
                        result.getOrThrow().map { SearchHit(source, it) }
                    } else {
                        listOf(SearchHit(source, SearchBook(), result.exceptionOrNull()?.let(::friendlyError)))
                    }
                }
            }
        }
        val hits = jobs.flatMap { it.await() }
        saveSearchCache(hits.filter { it.error == null }.map { it.book })
        hits
    }

    suspend fun explore(
        source: BookSource,
        url: String,
        page: Int = 1
    ): List<SearchBook> = WebBook.exploreBookAwait(source, url, page)

    // ---------------------------------------------------------------- 详情 / 目录

    /** 用详情页地址 + 书源构造 Book */
    fun buildBook(bookUrl: String, source: BookSource): Book {
        return Book(
            bookUrl = bookUrl,
            tocUrl = bookUrl,
            origin = source.bookSourceUrl,
            originName = source.bookSourceName,
            type = source.getBookType()
        )
    }

    suspend fun loadInfo(book: Book, source: BookSource): Book {
        return WebBook.getBookInfoAwait(source, book)
    }

    /**
     * 拉目录并写入内存 dao（BookContent 取"下一章地址"要用）。
     */
    suspend fun loadToc(book: Book, source: BookSource, runPreUpdateJs: Boolean = true): List<BookChapter> {
        val chapters = WebBook.getChapterListAwait(source, book, runPreUpdateJs).getOrThrow()
        appDb.bookChapterDao.deleteByBook(book.bookUrl)
        appDb.bookChapterDao.insert(*chapters.toTypedArray())
        return chapters
    }

    suspend fun loadContent(
        book: Book,
        source: BookSource,
        chapter: BookChapter,
        nextChapterUrl: String? = null
    ): String {
        return WebBook.getContentAwait(source, book, chapter, nextChapterUrl, needSave = false)
    }

    // ---------------------------------------------------------------- 书籍定位

    /** 把 "URL / 序号 / 名字" 统一解析成 (Book, BookSource) */
    fun resolveBook(selector: String): Pair<Book, BookSource> {
        if (selector.startsWith("http://") || selector.startsWith("https://")) {
            val source = SourceStore.matchByBookUrl(selector)
                ?: error("没有书源能匹配这个地址：$selector\n可用 source list 查看书源，或用 --source 指定")
            return buildBook(selector, source) to source
        }
        val index = selector.toIntOrNull()
        if (index != null) {
            val cached = loadSearchCache()
            if (cached.isEmpty()) error("还没有搜索结果，先执行 search 命令")
            val book = cached.getOrNull(index - 1)
                ?: error("序号越界：$index（上次搜索共 ${cached.size} 条）")
            val source = SourceStore.all().firstOrNull { it.bookSourceUrl == book.origin }
                ?: sourceForBook(book)
            return book.toBook() to source
        }
        // 名字：先查搜索缓存，再全文匹配书源
        val cached = loadSearchCache().firstOrNull { it.name == selector }
        if (cached != null) {
            return cached.toBook() to sourceForBook(cached)
        }
        error("无法识别的书籍标识：$selector（需要详情页 URL、搜索结果序号或书名）")
    }

    private fun sourceForBook(book: SearchBook): BookSource {
        return SourceStore.all().firstOrNull { it.bookSourceUrl == book.origin }
            ?: SourceStore.matchByBookUrl(book.bookUrl)
            ?: error("找不到书籍来源书源：${book.origin}")
    }

    // ---------------------------------------------------------------- 搜索缓存

    private fun searchCacheFile(): File = File(Cli.dataDir, "last-search.json")

    fun saveSearchCache(books: List<SearchBook>) {
        runCatching {
            searchCacheFile().writeText(CLI_GSON.toJson(books))
        }
    }

    fun loadSearchCache(): List<SearchBook> {
        val f = searchCacheFile()
        if (!f.isFile) return emptyList()
        return runCatching {
            CLI_GSON.fromJson(f.readText(), Array<SearchBook>::class.java).toList()
        }.getOrDefault(emptyList())
    }

    // ---------------------------------------------------------------- 工具

    /** 把异常信息压缩成一行，去掉巨长的堆栈 */
    fun friendlyError(e: Throwable): String {
        val msg = e.message?.trim().orEmpty()
        val head = if (msg.isNotEmpty()) msg else e.javaClass.simpleName
        return head.lineSequence().firstOrNull()?.take(160) ?: head.take(160)
    }

    /** 带退避重试 */
    suspend fun <T> retry(times: Int, block: suspend (attempt: Int) -> T): T {
        var lastError: Throwable? = null
        for (i in 0..times) {
            try {
                return block(i)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Throwable) {
                lastError = e
                if (i < times) delay(400L * (i + 1))
            }
        }
        throw lastError ?: IllegalStateException("未知错误")
    }

    val isImageSource: (BookSource) -> Boolean = { it.bookSourceType == BookSourceType.image }

    val isTextSource: (BookSource) -> Boolean = {
        it.bookSourceType == BookSourceType.default || it.bookSourceType == BookSourceType.file
    }

    /** 章节分组目录名：0001-标题 */
    fun chapterDirName(chapter: BookChapter): String {
        return String.format("%05d-%s", chapter.index + 1, sanitizeFileName(chapter.title, "未命名章节"))
    }

    fun bookTypeName(type: Int): String = when {
        type and BookType.image != 0 -> "图片"
        type and BookType.audio != 0 -> "音频"
        type and BookType.webFile != 0 -> "文件"
        else -> "文本"
    }
}
