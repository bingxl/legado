package io.legado.cli

import io.legado.app.data.entities.Book
import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.help.ConcurrentRateLimiter
import io.legado.app.help.config.CliStorage
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.NetworkUtils
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.jsoup.Jsoup
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * 下载器：M1 纯文本、M2 图片漫画。
 *
 * 章节页本身的抓取全部走 WebBook/AnalyzeUrl（自带并发率与 Cookie），
 * 图片、音频这类二进制资源走这里自己的 OkHttp 分支，并复用同一套
 * ConcurrentRateLimiter 保证与书源 concurrentRate 一致。
 */
object Download {

    data class Summary(
        val total: Int,
        val success: Int,
        val failed: Int,
        val skipped: Int,
        val outputDir: File
    )

    // ------------------------------------------------------------ 对外入口

    suspend fun run(
        book: Book,
        source: BookSource,
        selected: List<BookChapter>,
        allChapters: List<BookChapter>,
        outDir: File,
        resume: Boolean
    ): Summary {
        if (selected.isEmpty()) error("章节范围为空")
        outDir.mkdirs()
        val imageMode = Pipeline.isImageSource(source) ||
            book.type and io.legado.app.constant.BookType.image != 0
        return if (imageMode) {
            downloadImages(book, source, selected, outDir, resume)
        } else {
            downloadText(book, source, selected, allChapters, outDir, resume)
        }
    }

    /**
     * 章节挑选：支持 --from/--to 区间，以及 --chapters 1,3,5-9 精确列表（1 起算）。
     */
    fun selectChapters(
        chapters: List<BookChapter>,
        from: Int?,
        to: Int?,
        only: List<IntRange>? = null
    ): List<BookChapter> {
        if (only != null) {
            return chapters.filter { c -> only.any { (c.index + 1) in it } }
        }
        val start = (from ?: 1).coerceAtLeast(1) - 1
        val end = (to ?: chapters.size).coerceAtMost(chapters.size)
        if (start >= end) return emptyList()
        return chapters.subList(start, end).toList()
    }

    /** 解析 "1,3,5-9" */
    fun parseRanges(text: String): List<IntRange> {
        return text.split(',').mapNotNull { part ->
            val p = part.trim()
            if (p.isEmpty()) return@mapNotNull null
            if (p.contains('-')) {
                val (a, b) = p.split('-', limit = 2)
                val s = a.trim().toIntOrNull()
                val e = b.trim().toIntOrNull()
                if (s == null || e == null || s > e) null else s..e
            } else {
                p.toIntOrNull()?.let { it..it }
            }
        }
    }

    // ------------------------------------------------------------ M1 文本

    private suspend fun downloadText(
        book: Book,
        source: BookSource,
        chapters: List<BookChapter>,
        allChapters: List<BookChapter>,
        outDir: File,
        resume: Boolean
    ): Summary {
        val chapterDir = File(outDir, "chapters").apply { mkdirs() }
        val ok = AtomicInteger()
        val fail = AtomicInteger()
        val skip = AtomicInteger()
        val failures = java.util.Collections.synchronizedList(ArrayList<String>())
        val semaphore = Semaphore(Cli.jobs)
        val started = System.currentTimeMillis()
        val total = chapters.size

        val results = coroutineScope {
            chapters.map { chapter ->
                async(Dispatchers.IO) {
                    semaphore.withPermit {
                        val file = File(chapterDir, Pipeline.chapterDirName(chapter) + ".txt")
                        if (resume && file.isFile && file.length() > 0) {
                            skip.incrementAndGet()
                            reportProgress(ok.get(), skip.get(), fail.get(), total, started)
                            return@withPermit file.readText() to chapter
                        }
                        // 下一章地址用于让"下一页"规则在遇到下一章时停下
                        val nextUrl = allChapters.getOrNull(chapter.index + 1)?.url
                        runCatching {
                            Pipeline.retry(Cli.retries) {
                                Pipeline.loadContent(book, source, chapter, nextUrl)
                            }
                        }.onSuccess { content ->
                            file.writeText(toPlainText(content))
                            ok.incrementAndGet()
                        }.onFailure { e ->
                            fail.incrementAndGet()
                            failures.add("${chapter.index + 1}. ${chapter.title}  ⇒ ${Pipeline.friendlyError(e)}")
                        }
                        reportProgress(ok.get(), skip.get(), fail.get(), total, started)
                        (file.takeIf { it.isFile }?.readText() ?: "") to chapter
                    }
                }
            }.map { it.await() }
        }

        val txt = buildString {
            appendLine(book.name.ifBlank { "未知书名" })
            book.author.takeIf { it.isNotBlank() }?.let { appendLine("作者：$it") }
            book.kind?.takeIf { it.isNotBlank() }?.let { appendLine("分类：$it") }
            book.intro?.takeIf { it.isNotBlank() }?.let { appendLine("简介：$it") }
            appendLine("来源：${source.bookSourceName}  ${book.bookUrl}")
            appendLine("章节：${total}")
            appendLine()
            results.forEach { (content, chapter) ->
                appendLine(chapter.title)
                appendLine()
                appendLine(content.trim())
                appendLine()
            }
        }
        val outFile = File(outDir, sanitizeFileName(book.name.ifBlank { "book" }) + ".txt")
        outFile.writeText(txt)

        Out.progress("", done = true)
        if (failures.isNotEmpty()) {
            val failFile = File(outDir, "_failures.txt")
            failFile.writeText(failures.joinToString("\n"))
            Out.warn("失败 ${failures.size} 章，明细见 ${failFile.absolutePath}")
        }
        return Summary(total, ok.get(), fail.get(), skip.get(), outDir)
    }

    /** 文本源落盘前把 HTML 残留（图片、换行标签）转成纯文本 */
    private fun toPlainText(content: String): String {
        if (!content.contains('<')) return content
        return content
            .replace(Regex("(?i)<br\\s*/?>"), "\n")
            .replace(Regex("(?i)</p\\s*>"), "\n")
            .replace(Regex("(?i)<img[^>]*>"), "")
            .replace(Regex("(?i)<[^>]{1,80}>"), "")
            .replace("&nbsp;", " ")
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()
    }

    // ------------------------------------------------------------ M2 图片

    private suspend fun downloadImages(
        book: Book,
        source: BookSource,
        chapters: List<BookChapter>,
        outDir: File,
        resume: Boolean
    ): Summary {
        val ok = AtomicInteger()
        val fail = AtomicInteger()
        val skip = AtomicInteger()
        val failures = java.util.Collections.synchronizedList(ArrayList<String>())
        val limiter = ConcurrentRateLimiter(source)
        val sourceHeaders = runCatching { source.getHeaderMap(true) }.getOrDefault(HashMap())
        val started = System.currentTimeMillis()
        val total = chapters.size
        var totalImages = 0

        chapters.forEach { chapter ->
            val chapterUrl = runCatching { chapter.getAbsoluteURL() }.getOrNull() ?: chapter.url
            val dir = File(outDir, Pipeline.chapterDirName(chapter)).apply { mkdirs() }

            val html = runCatching {
                Pipeline.retry(Cli.retries) {
                    Pipeline.loadContent(book, source, chapter, null)
                }
            }.getOrElse { e ->
                fail.incrementAndGet()
                failures.add("${chapter.index + 1}. ${chapter.title}  ⇒ ${Pipeline.friendlyError(e)}")
                reportProgress(chapter.index + 1, skip.get(), fail.get(), total, started)
                return@forEach
            }

            val urls = extractImageUrls(html, chapterUrl)
            if (urls.isEmpty()) {
                fail.incrementAndGet()
                failures.add("${chapter.index + 1}. ${chapter.title}  ⇒ 未解析到图片")
                reportProgress(chapter.index + 1, skip.get(), fail.get(), total, started)
                return@forEach
            }
            totalImages += urls.size

            coroutineScope {
                val semaphore = Semaphore(Cli.jobs)
                urls.mapIndexed { i, imageUrl ->
                    async(Dispatchers.IO) {
                        semaphore.withPermit {
                            val record = limiter.getConcurrentRecord()
                            try {
                                if (resume && existingImage(dir, i + 1) != null) {
                                    skip.incrementAndGet()
                                    return@withPermit
                                }
                                fetchBinary(imageUrl, dir, i + 1, chapterUrl, sourceHeaders)
                            } catch (e: Throwable) {
                                fail.incrementAndGet()
                                failures.add(
                                    "${chapter.index + 1}. ${chapter.title} 图${i + 1}  ⇒ " +
                                        "${Pipeline.friendlyError(e)}\n    $imageUrl"
                                )
                            } finally {
                                limiter.fetchEnd(record)
                            }
                        }
                    }
                }.forEach { it.await() }
            }
            ok.incrementAndGet()
            reportProgress(chapter.index + 1, skip.get(), fail.get(), total, started, totalImages)
        }

        Out.progress("", done = true)
        if (failures.isNotEmpty()) {
            val failFile = File(outDir, "_failures.txt")
            failFile.writeText(failures.joinToString("\n"))
            Out.warn("失败 ${failures.size} 项，明细见 ${failFile.absolutePath}")
        }
        return Summary(total, ok.get(), fail.get(), skip.get(), outDir)
    }

    /**
     * 从正文 HTML 里抽出图片地址。
     * legado 的 formatKeepImg 会把 <img> 统一成 `<img src="绝对地址">`，
     * 少数书源用 `,{"headers":{...}}` 追加单图请求头，这里一并解析。
     */
    fun extractImageUrls(html: String, chapterUrl: String): List<String> {
        val trimmed = html.trim()
        if (trimmed.isEmpty()) return emptyList()

        // 少数图片源正文规则直接返回换行分隔的 URL 列表
        if (!trimmed.contains('<')) {
            return trimmed.split('\n')
                .map { it.trim() }
                .filter { it.startsWith("http") || it.startsWith("//") || it.startsWith("data:") }
                .map { NetworkUtils.getAbsoluteURL(chapterUrl, it) }
        }

        val doc = Jsoup.parseBodyFragment(trimmed)
        doc.outputSettings().prettyPrint(false)
        val list = ArrayList<String>()
        doc.select("img").forEach { img ->
            val src = img.attr("src").ifBlank { img.attr("data-src") }
                .ifBlank { img.attr("data-original") }
            if (src.isBlank()) return@forEach
            if (isPlaceholder(src)) return@forEach
            val abs = if (src.startsWith("data:")) src else NetworkUtils.getAbsoluteURL(chapterUrl, src)
            if (abs.isNotBlank()) list.add(abs)
        }
        // 去重但保留顺序（同一张图重复出现也算一张）
        return list.distinct()
    }

    private fun isPlaceholder(url: String): Boolean {
        if (url.startsWith("data:")) return false
        val lower = url.lowercase()
        return lower.contains("load.gif") ||
            lower.contains("loading.gif") ||
            lower.contains("placeholder") ||
            lower.contains("spacer.") ||
            lower.contains("blank.gif")
    }

    /** data:image/xxx;base64,... 内联图片直接解码落盘 */
    private fun writeDataUri(uri: String, dir: File, index: Int): File {
        val comma = uri.indexOf(',')
        if (comma < 0) error("非法 data URI")
        val meta = uri.substring(5, comma)
        val payload = uri.substring(comma + 1)
        val raw = if (meta.contains("base64", true)) {
            java.util.Base64.getDecoder().decode(payload)
        } else {
            java.net.URLDecoder.decode(payload, "UTF-8").toByteArray()
        }
        if (raw.isEmpty()) error("data URI 内容为空")
        val ext = when {
            meta.contains("png", true) -> "png"
            meta.contains("webp", true) -> "webp"
            meta.contains("gif", true) -> "gif"
            else -> "jpg"
        }
        val target = File(dir, String.format("%04d.%s", index, ext))
        target.writeBytes(raw)
        return target
    }

    /** 已存在的图片文件（0001.jpg 之类），用于断点续传 */
    private fun existingImage(dir: File, index: Int): File? {
        val prefix = String.format("%04d.", index)
        return dir.listFiles()?.firstOrNull {
            it.isFile && it.name.startsWith(prefix) && it.length() > 0
        }
    }

    /**
     * 下载二进制到目标目录，先写临时文件再按真实 Content-Type 决定扩展名。
     * 返回最终落盘的文件。
     */
    private fun fetchBinary(
        url: String,
        dir: File,
        index: Int,
        referer: String,
        sourceHeaders: Map<String, String>
    ): File {
        val (pureUrl, extraHeaders) = splitUrlParams(url)
        if (pureUrl.startsWith("data:")) {
            return writeDataUri(pureUrl, dir, index)
        }
        val builder = Request.Builder().url(pureUrl)
        sourceHeaders.forEach { (k, v) -> builder.header(k, v) }
        extraHeaders.forEach { (k, v) -> builder.header(k, v) }
        if (builder.build().header("Referer") == null) {
            builder.header("Referer", referer)
        }
        val tmp = File(dir, String.format("%04d.part", index))
        okHttpClient.newCall(builder.build()).execute().use { response ->
            if (!response.isSuccessful) error("HTTP ${response.code}")
            val body = response.body ?: error("响应体为空")
            tmp.outputStream().use { out -> body.byteStream().copyTo(out) }
            if (tmp.length() <= 0) {
                tmp.delete()
                error("文件为空")
            }
            val ext = extensionOf(pureUrl, response.header("Content-Type"))
            val target = File(dir, String.format("%04d.%s", index, ext))
            if (target.exists()) target.delete()
            if (!tmp.renameTo(target)) {
                tmp.copyTo(target, overwrite = true)
                tmp.delete()
            }
            return target
        }
    }

    /** 依据 URL / Content-Type 决定扩展名 */

    private fun extensionOf(url: String, contentType: String?): String {
        val fromType = when {
            contentType == null -> null
            contentType.contains("jpeg", true) || contentType.contains("jpg", true) -> "jpg"
            contentType.contains("png", true) -> "png"
            contentType.contains("webp", true) -> "webp"
            contentType.contains("gif", true) -> "gif"
            contentType.contains("bmp", true) -> "bmp"
            contentType.contains("avif", true) -> "avif"
            else -> null
        }
        if (fromType != null && contentType?.contains("image", true) == true) return fromType
        val path = url.substringBefore('?').substringBefore('#')
        val ext = path.substringAfterLast('.', "").lowercase()
        return if (ext in setOf("jpg", "jpeg", "png", "webp", "gif", "bmp", "avif")) {
            if (ext == "jpeg") "jpg" else ext
        } else {
            fromType ?: "jpg"
        }
    }

    /** 拆出 legado 的内联参数：`url,{"headers":{...}}` */
    private fun splitUrlParams(url: String): Pair<String, Map<String, String>> {
        val idx = url.indexOf(",{")
        if (idx <= 0) return url to emptyMap()
        val pure = url.substring(0, idx)
        val jsonText = url.substring(idx + 1)
        val headers = runCatching {
            val obj = com.google.gson.JsonParser.parseString(jsonText).asJsonObject
            val map = HashMap<String, String>()
            obj.getAsJsonObject("headers")?.entrySet()?.forEach { e ->
                map[e.key] = e.value.asString
            }
            obj.get("referer")?.asString?.let { map["Referer"] = it }
            map
        }.getOrDefault(emptyMap())
        return pure to headers
    }

    // ------------------------------------------------------------ 进度

    private fun reportProgress(
        done: Int,
        skipped: Int,
        failed: Int,
        total: Int,
        started: Long,
        images: Int = 0
    ) {
        val extra = if (images > 0) " 图${images}" else ""
        Out.progress(
            "章节 $done/$total  跳过 $skipped 失败 $failed$extra  用时 ${Out.elapsed(started)}"
        )
    }

    /** 默认输出目录：<books>/<书名> */
    fun defaultOutputDir(book: Book): File {
        val base = File(CliStorage.booksDir, sanitizeFileName(book.name.ifBlank { "book" }))
        base.mkdirs()
        return base
    }
}
