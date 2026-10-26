package io.legado.cli

import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.CliStorage
import io.legado.app.model.Debug
import java.io.File

/**
 * CLI 全局运行时状态：数据目录、并发数、日志开关。
 */
object Cli {

    /** 数据根目录，默认 ~/.legado-cli */
    var dataDir: File = CliStorage.dataDir
        private set

    /** 章节 / 图片下载并发数 */
    var jobs: Int = 8

    /** 单章失败重试次数 */
    var retries: Int = 2

    /** 打印书源执行过程（等价 App 里的调试日志） */
    var verbose: Boolean = false

    /** 结果以 JSON 输出 */
    var json: Boolean = false

    /** 不输出进度条等过程信息 */
    var quiet: Boolean = false

    fun setup(options: Options) {
        options.value("dir")?.let { dataDir = File(expandHome(it)).absoluteFile }
        CliStorage.reset(dataDir)
        dataDir.mkdirs()
        options.value("jobs")?.toIntOrNull()?.let { jobs = it.coerceIn(1, 64) }
        options.value("retries")?.toIntOrNull()?.let { retries = it.coerceIn(0, 10) }
        options.value("timeout")?.toLongOrNull()?.let { AppConfig.timeoutSeconds = it }
        options.value("ua")?.let { AppConfig.userAgent = it }
        options.value("proxy")?.let { AppConfig.proxy = it }
        verbose = options.has("verbose") || options.has("debug")
        json = options.has("json")
        quiet = options.has("quiet")
        Debug.verbose = verbose
        AppConfig.threadCount = jobs
    }

    private fun expandHome(path: String): String {
        if (path == "~") return System.getProperty("user.home")
        if (path.startsWith("~/") || path.startsWith("~\\")) {
            return System.getProperty("user.home") + path.substring(1)
        }
        return path
    }
}

/**
 * 极简参数解析：支持 `--key value` / `--key=value` / 单独 `--flag`，其余为位置参数。
 */
class Options(raw: List<String>) {

    private val map = LinkedHashMap<String, String>()
    val positional = ArrayList<String>()

    init {
        var i = 0
        while (i < raw.size) {
            val token = raw[i]
            when {
                token.startsWith("--") -> {
                    val body = token.substring(2)
                    val eq = body.indexOf('=')
                    if (eq > 0) {
                        map[body.substring(0, eq)] = body.substring(eq + 1)
                    } else {
                        val next = raw.getOrNull(i + 1)
                        if (next != null && !next.startsWith("--")) {
                            map[body] = next
                            i++
                        } else {
                            map[body] = ""
                        }
                    }
                }

                else -> positional.add(token)
            }
            i++
        }
    }

    fun value(key: String): String? = map[key]?.takeIf { it.isNotEmpty() }

    fun raw(key: String): String? = map[key]

    fun has(key: String): Boolean = map.containsKey(key)

    fun int(key: String): Int? = value(key)?.toIntOrNull()

    fun bool(key: String): Boolean = has(key)
}

/** 终端输出：CJK 宽度对齐的表格 + 进度信息 */
object Out {

    /** --json 时把过程信息挤到 stderr，保证 stdout 只有 JSON */
    private fun processStream(): java.io.PrintStream = if (Cli.json) System.err else System.out

    fun info(msg: String) {
        if (!Cli.quiet) processStream().println(msg)
    }

    fun warn(msg: String) {
        processStream().println(msg)
    }

    fun error(msg: String) {
        System.err.println(msg)
    }

    /** 进度：同一行刷新，避免刷屏；done=true 时换行收尾 */
    fun progress(text: String, done: Boolean = false) {
        if (Cli.quiet || Cli.json) return
        if (done) {
            print("\r$text\n")
        } else {
            print("\r$text")
        }
        System.out.flush()
    }

    fun table(headers: List<String>, rows: List<List<String>>) {
        if (rows.isEmpty()) {
            println("（无数据）")
            return
        }
        val widths = headers.indices.map { i ->
            maxOf(
                displayWidth(headers[i]),
                rows.maxOf { displayWidth(it.getOrElse(i) { "" }) }
            )
        }
        println(headers.mapIndexed { i, h -> pad(h, widths[i]) }.joinToString("  "))
        println(widths.joinToString("  ") { "-".repeat(it) })
        rows.forEach { row ->
            println(row.mapIndexed { i, cell -> pad(cell, widths[i]) }.joinToString("  "))
        }
    }

    private fun pad(text: String, width: Int): String {
        val w = displayWidth(text)
        return if (w >= width) text else text + " ".repeat(width - w)
    }

    /** 中文/全角按 2 列宽计算，保证表格不错位 */
    private fun displayWidth(text: String): Int {
        var w = 0
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            w += if (isWide(cp)) 2 else 1
            i += Character.charCount(cp)
        }
        return w
    }

    private fun isWide(cp: Int): Boolean {
        return cp in 0x1100..0x115F ||
            cp in 0x2E80..0xA4CF ||
            cp in 0xAC00..0xD7A3 ||
            cp in 0xF900..0xFAFF ||
            cp in 0xFE30..0xFE6F ||
            cp in 0xFF00..0xFF60 ||
            cp in 0xFFE0..0xFFE6 ||
            cp in 0x1F300..0x1F9FF
    }

    fun elapsed(start: Long): String {
        val ms = System.currentTimeMillis() - start
        return if (ms < 1000) "${ms}ms" else String.format("%.1fs", ms / 1000.0)
    }
}

/** 文件名清洗：去掉 Windows / Linux 都不允许的字符 */
fun sanitizeFileName(name: String, fallback: String = "未命名"): String {
    val cleaned = name
        .replace(Regex("""[\\/:*?"<>|\r\n\t]"""), "_")
        .replace(Regex("""\s+"""), " ")
        .trim()
        .trimEnd('.')
        .take(80)
    return cleaned.ifBlank { fallback }
}
