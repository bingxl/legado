package io.legado.cli

import com.google.gson.JsonElement
import com.google.gson.JsonParser
import io.legado.app.data.appDb
import io.legado.app.data.entities.BookSource
import io.legado.app.utils.GSON
import java.io.File

/**
 * 书源仓库：把书源 JSON 落到 <data>/sources.json，并负责按名字/URL 检索。
 *
 * 支持导入的 JSON 形态：
 *  - 单个书源对象 `{ "bookSourceName": ... }`
 *  - 书源数组 `[ {...}, {...} ]`
 *  - 目录（递归读取其中的 *.json）
 */
object SourceStore {

    private val file: File get() = File(Cli.dataDir, "sources.json")

    @Volatile
    private var cache: MutableList<BookSource>? = null

    fun all(): List<BookSource> = load()

    private fun load(): MutableList<BookSource> {
        cache?.let { return it }
        val list = ArrayList<BookSource>()
        if (file.isFile) {
            runCatching {
                list.addAll(parseFile(file))
            }.onFailure {
                Out.error("读取书源文件失败: ${it.message}")
            }
        }
        // 同步进内存 dao，供 BookSourcePart.getBookSource() / 调试使用
        list.forEach { appDb.bookSourceDao.insert(it) }
        cache = list
        return list
    }

    fun save(list: List<BookSource>) {
        file.parentFile?.mkdirs()
        file.writeText(CLI_GSON.toJson(list))
        cache = list.toMutableList()
        appDb.bookSourceDao.let { dao ->
            list.forEach { dao.insert(it) }
        }
    }

    /** 导入：返回 (新增, 更新) */
    fun importFrom(path: String): Pair<Int, Int> {
        val target = File(path)
        if (!target.exists()) error("文件不存在: $path")
        val incoming = if (target.isDirectory) {
            target.walkTopDown()
                .filter { it.isFile && it.extension.equals("json", true) }
                .sortedBy { it.path }
                .flatMap { f -> parseFile(f) }
                .toList()
        } else {
            parseFile(target)
        }
        if (incoming.isEmpty()) error("没有解析到任何书源: $path")

        val list = load()
        var added = 0
        var updated = 0
        incoming.forEach { src ->
            if (src.bookSourceUrl.isBlank()) return@forEach
            val i = list.indexOfFirst { it.bookSourceUrl == src.bookSourceUrl }
            if (i >= 0) {
                list[i] = src
                updated++
            } else {
                list.add(src)
                added++
            }
        }
        save(list)
        return added to updated
    }

    fun remove(selector: String): List<BookSource> {
        val list = load()
        val removed = list.filter { match(it, selector) }
        if (removed.isNotEmpty()) {
            list.removeAll(removed)
            save(list)
        }
        return removed
    }

    /**
     * 解析单/多书源 JSON。兼容 BOM、以及 `{"sources":[...]}` 形式。
     */
    fun parseFile(f: File): List<BookSource> {
        val text = f.readText().removePrefix("\uFEFF")
        if (text.isBlank()) return emptyList()
        val root = JsonParser.parseString(text)
        return parseElement(root)
    }

    private fun parseElement(root: JsonElement): List<BookSource> {
        val result = ArrayList<BookSource>()
        when {
            root.isJsonArray -> root.asJsonArray.forEach { el ->
                result.addAll(parseElement(el))
            }

            root.isJsonObject -> {
                val obj = root.asJsonObject
                // 订阅文件 / 包装形态
                val inner = obj.get("sources") ?: obj.get("bookSources") ?: obj.get("data")
                if (inner != null && inner.isJsonArray && !obj.has("bookSourceUrl")) {
                    result.addAll(parseElement(inner))
                } else if (obj.has("bookSourceUrl") || obj.has("bookSourceName")) {
                    runCatching {
                        CLI_GSON.fromJson(obj, BookSource::class.java)
                    }.onSuccess { if (it != null) result.add(it) }
                        .onFailure { Out.error("书源解析失败: ${it.message}") }
                }
            }
        }
        return result
    }

    /** 按 selector（名字片段 / URL / 序号）挑选书源 */
    fun select(selector: String?): List<BookSource> {
        val list = load().filter { it.enabled }
        if (selector.isNullOrBlank() || selector == "all") return list
        val byNumber = selector.toIntOrNull()
        if (byNumber != null && byNumber in 1..load().size) {
            return listOf(load()[byNumber - 1])
        }
        val hit = list.filter { match(it, selector) }
        if (hit.isEmpty()) {
            error("没有匹配的书源: $selector（用 source list 查看可用书源）")
        }
        return hit
    }

    private fun match(source: BookSource, selector: String): Boolean {
        return source.bookSourceUrl.equals(selector, true) ||
            source.bookSourceName == selector ||
            source.bookSourceName.contains(selector, true) ||
            source.bookSourceUrl.contains(selector, true)
    }

    /**
     * 根据书籍详情页地址反查书源：先看 bookUrlPattern，再看域名。
     */
    fun matchByBookUrl(bookUrl: String): BookSource? {
        val list = load().filter { it.enabled }
        list.firstOrNull { s ->
            val pattern = s.bookUrlPattern
            !pattern.isNullOrBlank() && runCatching { Regex(pattern).containsMatchIn(bookUrl) }
                .getOrDefault(false)
        }?.let { return it }
        val host = hostOf(bookUrl) ?: return null
        return list.firstOrNull { hostOf(it.bookSourceUrl) == host }
    }

    private fun hostOf(url: String): String? {
        return runCatching { java.net.URI(url).host?.lowercase()?.removePrefix("www.") }.getOrNull()
    }
}
