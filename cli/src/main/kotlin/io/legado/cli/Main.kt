package io.legado.cli

import io.legado.app.data.entities.BookChapter
import io.legado.app.data.entities.BookSource
import io.legado.app.data.entities.rule.ExploreKind
import io.legado.app.utils.GSON
import kotlinx.coroutines.runBlocking
import java.io.File
import kotlin.system.exitProcess

fun main(args: Array<String>) {
    // 控制台统一 UTF-8，避免 Windows 默认代码页把中文打成乱码
    System.setOut(java.io.PrintStream(java.io.FileOutputStream(java.io.FileDescriptor.out), true, "UTF-8"))
    System.setErr(java.io.PrintStream(java.io.FileOutputStream(java.io.FileDescriptor.err), true, "UTF-8"))

    if (args.isEmpty() || args[0] == "help" || args[0] == "-h" || args[0] == "--help") {
        printUsage()
        return
    }
    val command = args[0]
    val options = Options(args.drop(1))
    Cli.setup(options)

    try {
        when (command) {
            "source" -> sourceCommand(options)
            "search" -> runBlocking { searchCommand(options) }
            "explore" -> runBlocking { exploreCommand(options) }
            "info" -> runBlocking { infoCommand(options) }
            "toc" -> runBlocking { tocCommand(options) }
            "content" -> runBlocking { contentCommand(options) }
            "download", "dl" -> runBlocking { downloadCommand(options) }
            "selftest" -> selftest()
            "rule" -> runRule(options)
            "fetch" -> runFetch(options)
            "js" -> runJs(options)
            else -> {
                Out.error("未知命令: $command")
                printUsage()
                exitProcess(1)
            }
        }
    } catch (e: Throwable) {
        Out.error("✗ ${Pipeline.friendlyError(e)}")
        if (Cli.verbose) e.printStackTrace()
        exitProcess(1)
    }
    // OkHttp 的 Dispatcher 线程不是 daemon，不主动退出会让进程白等 60s
    exitProcess(0)
}

private fun printUsage() {
    println(
        """
        legado-cli —— 直接跑 legado 的 Kotlin 书源引擎，下载小说 / 漫画

        用法:
          legado-cli <命令> [参数] [--选项]

        书源管理:
          source add <文件|目录>          导入书源（支持单个对象 / 数组 / 目录批量）
          source list                     列出已导入书源
          source remove <名字|域名>       删除书源
          source show <名字|域名>         查看书源原始 JSON

        书源能力:
          search <关键字>                 多书源并发搜索
              --source <名字|域名|all>        限定书源，默认全部
              --page <n>                      页码，默认 1
              --json                          输出 JSON
          explore --source <书源>         发现页
              --kind <分类名>                 按分类名挑（分类用 --list 查看）
              --url <地址>                    直接指定发现地址
              --page <n> / --list
          info <URL|序号|书名>            书籍详情
          toc  <URL|序号|书名>            目录（序号来自上次 search 结果）
              --limit <n>                     只显示前 n 章
          content <URL|序号|书名> --index <n>   单章正文

        下载:
          download <URL|序号|书名>        下载整本
              --from <n> --to <n>             章节区间（1 起算）
              --chapters 1,3,5-9              精确章节
              --out <目录>                    输出目录
              --resume                        断点续传（跳过已有文件）
              --jobs <n>                      并发数
          文本源输出 <out>/<书名>.txt；图片源输出 <out>/<章节>/0001.jpg

        全局选项（任意命令可用）:
          --dir <目录>      数据目录，默认 ~/.legado-cli
          --jobs <n>        并发数，默认 8
          --retries <n>     失败重试次数，默认 2
          --timeout <秒>    请求超时
          --proxy <地址>    形如 http://127.0.0.1:7890
          --verbose         打印书源执行日志（调试规则用）
          --json            结果转 JSON
          --quiet           不打印进度

        调试:
          selftest                         规则引擎自检
          rule --rule <规则> --html/--url  单条规则解析
          js --code <脚本>                 跑一段 JS
          fetch --url <地址>               抓页面

        示例:
          legado-cli source add yumanhua_comic_source.json
          legado-cli search 斗破苍穹 --source all
          legado-cli info https://www.example.com/book/123
          legado-cli toc 1
          legado-cli download 1 --from 1 --to 20 --resume
          legado-cli download 1 --chapters 1,5,9-12 --jobs 16
        """.trimIndent()
    )
}

// ==================================================================== 书源管理

private fun sourceCommand(options: Options) {
    val sub = options.positional.firstOrNull() ?: "list"
    val arg = options.positional.getOrNull(1)
    when (sub) {
        "add", "import" -> {
            val path = arg ?: error("用法: source add <文件|目录>")
            val (added, updated) = SourceStore.importFrom(path)
            Out.info("✓ 导入完成：新增 $added，更新 $updated，当前共 ${SourceStore.all().size} 个书源")
            Out.info("  书源文件：${File(Cli.dataDir, "sources.json").absolutePath}")
        }

        "list", "ls" -> {
            val list = SourceStore.all()
            if (list.isEmpty()) {
                Out.warn("还没有书源，先执行: legado-cli source add <书源.json>")
                return
            }
            val typeName = { t: Int -> when (t) { 1 -> "音频"; 2 -> "图片"; 3 -> "文件"; else -> "文本" } }
            Out.table(
                listOf("#", "名称", "类型", "分组", "搜索", "发现", "域名"),
                list.mapIndexed { i, s ->
                    listOf(
                        (i + 1).toString(),
                        s.bookSourceName,
                        typeName(s.bookSourceType),
                        s.bookSourceGroup ?: "",
                        if (s.searchUrl.isNullOrBlank()) "—" else "✓",
                        if (s.exploreUrl.isNullOrBlank()) "—" else "✓",
                        s.bookSourceUrl
                    )
                }
            )
        }

        "remove", "rm", "del" -> {
            val sel = arg ?: error("用法: source remove <名字|域名>")
            val removed = SourceStore.remove(sel)
            if (removed.isEmpty()) {
                Out.warn("没有匹配的书源: $sel")
            } else {
                Out.info("✓ 已删除 ${removed.size} 个书源：${removed.joinToString { it.bookSourceName }}")
            }
        }

        "show" -> {
            val sel = arg ?: error("用法: source show <名字|域名>")
            val list = SourceStore.select(sel)
            println(CLI_GSON.toJson(list))
        }

        else -> error("未知子命令: $sub（可用 add / list / remove / show）")
    }
}

// ==================================================================== 搜索

private suspend fun searchCommand(options: Options) {
    val keyword = options.positional.joinToString(" ").trim()
    if (keyword.isEmpty()) error("用法: search <关键字> [--source 书源名]")
    val all = SourceStore.select(options.value("source"))
    val sources = all.filter { !it.searchUrl.isNullOrBlank() }
    if (sources.isEmpty()) {
        error("选中 ${all.size} 个书源里没有可搜索的（都没有 searchUrl）")
    }
    if (sources.size < all.size) {
        Out.warn("跳过 ${all.size - sources.size} 个没有搜索地址的书源")
    }
    val page = options.int("page") ?: 1
    val started = System.currentTimeMillis()

    if (!Cli.quiet) Out.info("搜索「$keyword」  书源 ${sources.size} 个  并发 ${Cli.jobs}")

    val hits = Pipeline.search(keyword, sources, page) { source, count, error ->
        val name = source.bookSourceName
        if (error != null) {
            Out.progress("· $name  失败：$error", done = true)
        } else {
            Out.progress("· $name  $count 条", done = true)
        }
    }

    val books = hits.filter { it.error == null }.map { it.book }
    val errors = hits.filter { it.error != null }

    if (Cli.json) {
        println(CLI_GSON.toJson(books))
        return
    }

    Out.info("")
    Out.info("共 ${books.size} 条结果，用时 ${Out.elapsed(started)}")
    Out.info("")
    Out.table(
        listOf("#", "书名", "作者", "最新章节", "来源", "详情页"),
        books.mapIndexed { i, b ->
            listOf(
                (i + 1).toString(),
                b.name,
                b.author,
                b.latestChapterTitle ?: "",
                b.originName,
                b.bookUrl
            )
        }
    )
    if (errors.isNotEmpty()) {
        Out.info("")
        Out.warn("失败的源：")
        errors.forEach { Out.warn("  ${it.source.bookSourceName} ⇒ ${it.error}") }
    }
    if (books.isNotEmpty()) {
        Out.info("")
        Out.info("提示：序号已缓存，可直接 toc 1 / download 1")
    }
}

// ==================================================================== 发现

private suspend fun exploreCommand(options: Options) {
    val sources = SourceStore.select(options.value("source")).filter { !it.exploreUrl.isNullOrBlank() }
    if (sources.isEmpty()) error("没有带发现地址的书源")
    val source = sources.first()

    val kinds = parseExploreKinds(source)
    if (options.has("list") || kinds.isEmpty()) {
        Out.info("${source.bookSourceName} 的发现分类：")
        kinds.forEachIndexed { i, k -> Out.info("  ${i + 1}. ${k.title}") }
        if (kinds.isEmpty()) Out.warn("（该源没有解析出分类，可用 --url 直接指定发现地址）")
        if (options.has("list")) return
        return
    }

    val kindSelector = options.value("kind")
    val url = options.value("url") ?: run {
        val kind = if (kindSelector == null) {
            kinds.first()
        } else {
            kinds.getOrNull(kindSelector.toIntOrNull()?.minus(1) ?: -1)
                ?: kinds.firstOrNull { it.title == kindSelector }
                ?: kinds.firstOrNull { it.title.contains(kindSelector, true) }
                ?: error("没有分类: $kindSelector（用 --list 查看）")
        }
        kind.url ?: error("分类「${kind.title}」没有发现地址")
    }

    val page = options.int("page") ?: 1
    Out.info("发现：${source.bookSourceName}  $url  第 $page 页")
    val books = Pipeline.explore(source, url, page)
    // 与 search 共用"上次结果"缓存，这样接下来可以直接 info 1 / download 1
    Pipeline.saveSearchCache(books)
    if (Cli.json) {
        println(CLI_GSON.toJson(books))
        return
    }
    Out.table(
        listOf("#", "书名", "作者", "最新章节"),
        books.mapIndexed { i, b -> listOf((i + 1).toString(), b.name, b.author, b.latestChapterTitle ?: "") }
    )
}

/** 解析 exploreUrl：支持 `分类::地址` 换行/&&分隔，也兼容 JSON 数组 */
private fun parseExploreKinds(source: BookSource): List<ExploreKind> {
    val raw = source.exploreUrl?.takeIf { it.isNotBlank() } ?: return emptyList()
    if (raw.trimStart().startsWith("[")) {
        return runCatching {
            CLI_GSON.fromJson(raw, Array<ExploreKind>::class.java).toList()
        }.getOrDefault(emptyList())
    }
    if (raw.startsWith("@js:") || raw.startsWith("<js>", true)) {
        return emptyList()
    }
    return raw.split(Regex("(&&|\\n)+"))
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .map { line ->
            val parts = line.split("::", limit = 2)
            ExploreKind(title = parts[0].trim(), url = parts.getOrNull(1)?.trim())
        }
        .filter { it.title.isNotEmpty() }
}

// ==================================================================== 详情

private suspend fun infoCommand(options: Options) {
    val selector = selectorOf(options) ?: error("用法: info <URL|序号|书名>")
    val (book, source) = resolveBookWithSource(options, selector)
    val started = System.currentTimeMillis()
    Out.info("解析详情：${source.bookSourceName}  ${book.bookUrl}")
    Pipeline.loadInfo(book, source)

    if (Cli.json) {
        println(CLI_GSON.toJson(book))
        return
    }
    Out.info("")
    Out.info("书名    ${book.name}")
    Out.info("作者    ${book.author.ifBlank { "—" }}")
    Out.info("类型    ${Pipeline.bookTypeName(book.type)}")
    book.kind?.takeIf { it.isNotBlank() }?.let { Out.info("分类    $it") }
    book.wordCount?.takeIf { it.isNotBlank() }?.let { Out.info("字数    $it") }
    book.latestChapterTitle?.takeIf { it.isNotBlank() }?.let { Out.info("最新    $it") }
    book.coverUrl?.takeIf { it.isNotBlank() }?.let { Out.info("封面    $it") }
    Out.info("目录页  ${book.tocUrl}")
    Out.info("详情页  ${book.bookUrl}")
    book.intro?.takeIf { it.isNotBlank() }?.let {
        Out.info("")
        Out.info("简介")
        it.split('\n').forEach { line -> Out.info("  ${line.trim()}") }
    }
    Out.info("")
    Out.info("用时 ${Out.elapsed(started)}")
}

// ==================================================================== 目录

private suspend fun tocCommand(options: Options) {
    val selector = selectorOf(options) ?: error("用法: toc <URL|序号|书名>")
    val started = System.currentTimeMillis()
    val (book, source, chapters) = loadBookToc(options, selector)
    Out.info("目录：${book.name}  ${chapters.size} 章  用时 ${Out.elapsed(started)}")

    if (Cli.json) {
        println(CLI_GSON.toJson(chapters))
        return
    }
    val limit = options.int("limit") ?: 0
    val show = if (limit > 0) chapters.take(limit) else chapters
    Out.info("")
    Out.table(
        listOf("#", "章节", "标记"),
        show.map { c ->
            listOf(
                (c.index + 1).toString(),
                c.title,
                buildString {
                    if (c.isVolume) append("卷 ")
                    if (c.isVip) append("VIP ")
                    if (c.isPay) append("付费 ")
                    c.tag?.takeIf { it.isNotBlank() }?.let { append(it.take(20)) }
                }.trim()
            )
        }
    )
    if (limit in 1 until chapters.size) {
        Out.info("… 其余 ${chapters.size - limit} 章已省略（--limit 调整）")
    }
}

// ==================================================================== 正文

private suspend fun contentCommand(options: Options) {
    val selector = selectorOf(options) ?: error("用法: content <URL|序号|书名> --index <n>")
    val index = options.int("index")?.minus(1) ?: error("缺少 --index <章节序号，从 1 开始>")
    val (book, source, chapters) = loadBookToc(options, selector)
    val chapter = chapters.getOrNull(index) ?: error("章节序号越界：${index + 1}（共 ${chapters.size} 章）")
    val nextUrl = chapters.getOrNull(index + 1)?.url
    Out.info("正文：${chapter.title}  ${chapter.getAbsoluteURL()}")
    val content = Pipeline.loadContent(book, source, chapter, nextUrl)
    println()
    println(content)
}

// ==================================================================== 下载

private suspend fun downloadCommand(options: Options) {
    val selector = selectorOf(options) ?: error("用法: download <URL|序号|书名>")
    val started = System.currentTimeMillis()
    val (book, source, chapters) = loadBookToc(options, selector)

    val only = options.value("chapters")?.let { Download.parseRanges(it) }
    val selected = Download.selectChapters(chapters, options.int("from"), options.int("to"), only)
    if (selected.isEmpty()) error("章节范围为空（共 ${chapters.size} 章）")

    val outDir = options.value("out")?.let { File(it).absoluteFile } ?: Download.defaultOutputDir(book)
    val resume = options.has("resume")
    val imageMode = Pipeline.isImageSource(source)

    Out.info("")
    Out.info("开始下载  书名=${book.name}  源=${source.bookSourceName}")
    Out.info("  类型    ${if (imageMode) "图片（漫画）" else "文本"}")
    val rangeText = if (only != null) {
        val ids = selected.map { it.index + 1 }
        if (ids.size <= 10) {
            "第 " + ids.joinToString(",") + " 章"
        } else {
            "第 " + ids.take(10).joinToString(",") + " 等 ${ids.size} 章"
        }
    } else {
        "第 ${selected.first().index + 1} ~ ${selected.last().index + 1} 章"
    }
    Out.info("  章节    ${selected.size} / ${chapters.size}  （$rangeText）")
    Out.info("  并发    ${Cli.jobs}${if (resume) "  断点续传" else ""}")
    Out.info("  输出    ${outDir.absolutePath}")
    Out.info("")

    val summary = Download.run(book, source, selected, chapters, outDir, resume)

    Out.info("")
    Out.info("完成：成功 ${summary.success}  失败 ${summary.failed}  跳过 ${summary.skipped}  用时 ${Out.elapsed(started)}")
    Out.info("输出目录：${summary.outputDir.absolutePath}")
}

// ==================================================================== 公共

private fun selectorOf(options: Options): String? {
    return options.value("book") ?: options.positional.firstOrNull()
}

private fun resolveBookWithSource(
    options: Options,
    selector: String
): Pair<io.legado.app.data.entities.Book, BookSource> {
    options.value("source")?.let { sourceSelector ->
        val source = SourceStore.select(sourceSelector).firstOrNull()
            ?: error("没有匹配的书源: $sourceSelector")
        val url = if (selector.startsWith("http")) {
            selector
        } else {
            val cached = Pipeline.loadSearchCache().getOrNull((selector.toIntOrNull() ?: 0) - 1)
            cached?.bookUrl ?: error("用 --source 时需要给详情页 URL，或先 search 后传序号")
        }
        return Pipeline.buildBook(url, source) to source
    }
    return Pipeline.resolveBook(selector)
}

/** 详情 + 目录一次到位，返回 (book, source, chapters) */
private suspend fun loadBookToc(
    options: Options,
    selector: String
): Triple<io.legado.app.data.entities.Book, BookSource, List<BookChapter>> {
    val (book, source) = resolveBookWithSource(options, selector)
    Out.info("解析目录：${source.bookSourceName}  ${book.bookUrl}")
    Pipeline.loadInfo(book, source)
    return Triple(book, source, Pipeline.loadToc(book, source))
}

// ==================================================================== 调试命令

private fun loadBody(options: Options): String {
    options.value("html")?.let { return File(it).readText() }
    options.value("url")?.let { return fetch(it) }
    error("缺少 --html 或 --url")
}

private fun runRule(options: Options) {
    val rule = options.value("rule") ?: error("缺少 --rule")
    val body = loadBody(options)
    val result = when {
        rule.startsWith("$.") -> io.legado.app.model.analyzeRule.AnalyzeByJSonPath(body).getString(rule)
        rule.startsWith("//") || rule.startsWith("/html") ->
            io.legado.app.model.analyzeRule.AnalyzeByXPath(body).getString(rule)

        else -> io.legado.app.model.analyzeRule.AnalyzeByJSoup(body).getString(rule)
    }
    println(result ?: "<空>")
}

private fun runJs(options: Options) {
    val code = options.value("code") ?: options.value("file")?.let { File(it).readText() }
    ?: error("缺少 --code 或 --file")
    val result = com.script.rhino.RhinoScriptEngine.eval(code) {
        this["baseUrl"] = options.value("baseUrl") ?: "https://example.com"
        this["title"] = "第一章 测试"
    }
    println(result ?: "<空>")
}

private fun runFetch(options: Options) {
    val url = options.value("url") ?: error("缺少 --url")
    val body = fetch(url)
    options.value("output")?.let {
        File(it).writeText(body)
        println("已保存到 $it")
    } ?: println(body.take(2000))
}

private fun fetch(url: String): String = runBlocking {
    val request = okhttp3.Request.Builder().url(url).build()
    io.legado.app.help.http.okHttpClient.newCall(request).execute().use { response ->
        val body = response.body.string()
        println("HTTP ${response.code}  ${body.length} chars")
        body
    }
}

// ==================================================================== 自检

private const val SAMPLE_HTML = """
<html><head><title>示例</title></head>
<body>
<div class="list">
  <li class="book"><a href="/book/1">斗破苍穹</a><span class="author">天蚕土豆</span></li>
  <li class="book"><a href="/book/2">盗墓笔记</a><span class="author">南派三叔</span></li>
</div>
<img data-src="/img/cover.jpg" src="/img/placeholder.png"/>
</body></html>
"""

private const val SAMPLE_JSON = """
{"code":0,"data":{"books":[{"name":"斗破苍穹","author":"天蚕土豆"},{"name":"盗墓笔记","author":"南派三叔"}]}}
"""

private fun selftest() {
    var passed = 0
    var failed = 0

    fun check(name: String, expected: String, actual: String?) {
        if (actual?.trim() == expected) {
            println("  PASS  $name => $actual")
            passed++
        } else {
            println("  FAIL  $name => 期望[$expected] 实际[$actual]")
            failed++
        }
    }

    println("CSS 规则解析（AnalyzeByJSoup，legado 原码）")
    val jsoup = io.legado.app.model.analyzeRule.AnalyzeByJSoup(SAMPLE_HTML)
    check("class.list@tag.li@tag.a@text", "斗破苍穹\n盗墓笔记", jsoup.getString("class.list@tag.li@tag.a@text"))
    check("class.list@tag.li.1@tag.span@text", "南派三叔", jsoup.getString("class.list@tag.li.1@tag.span@text"))
    check("tag.img@data-src", "/img/cover.jpg", jsoup.getString("tag.img@data-src"))
    check("属性兜底 tag.img@src||data-src", "/img/placeholder.png", jsoup.getString("tag.img@src||data-src"))

    println("XPath 规则解析（AnalyzeByXPath，legado 原码）")
    val xpath = io.legado.app.model.analyzeRule.AnalyzeByXPath(SAMPLE_HTML)
    check("//ul/li/a/text()", "斗破苍穹\n盗墓笔记", xpath.getString("//div/li/a/text()"))

    println("JSONPath 规则解析（AnalyzeByJSonPath，legado 原码）")
    val json = io.legado.app.model.analyzeRule.AnalyzeByJSonPath(SAMPLE_JSON)
    check("$.data.books[*].name", "斗破苍穹\n盗墓笔记", json.getString("$.data.books[*].name"))

    println("JS 脚本执行（modules/rhino，legado 原码 + 2 处 Android 替身）")
    check("1+1", "2.0", com.script.rhino.RhinoScriptEngine.eval("1+1")?.toString())
    check(
        "baseUrl 绑定",
        "https://example.com/search?q=%E6%96%97%E7%A0%B4",
        com.script.rhino.RhinoScriptEngine.eval("baseUrl + '/search?q=' + encodeURIComponent('斗破')") {
            this["baseUrl"] = "https://example.com"
        }?.toString()
    )
    check(
        "Java 互操作",
        "1970",
        com.script.rhino.RhinoScriptEngine.eval(
            "new java.text.SimpleDateFormat('yyyy').format(new java.util.Date(0))"
        )?.toString()
    )
    check(
        "正则替换（书源常见写法）",
        "斗破苍穹 作者:天蚕土豆",
        com.script.rhino.RhinoScriptEngine.eval("'斗破苍穹-天蚕土豆'.replace('-', ' 作者:')")?.toString()
    )

    println()
    println("通过 $passed 项，失败 $failed 项")
    if (failed > 0) exitProcess(1)
}
