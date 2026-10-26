package io.legado.app.help.config

import java.io.File

/**
 * CLI 的目录约定：所有落盘内容集中在 --data 指定的目录下（默认 ~/.legado-cli）。
 *
 * <data>/
 * ├─ cache/       书源脚本缓存、cookie、键值缓存
 * └─ books/       下载产物
 */
object CliStorage {

    var dataDir: File = File(System.getProperty("user.home"), ".legado-cli")

    val cacheDir: File get() = File(dataDir, "cache").apply { mkdirs() }

    val booksDir: File get() = File(dataDir, "books").apply { mkdirs() }

    fun cacheFile(name: String): File = File(cacheDir, name)

    fun reset(dir: File) {
        dataDir = dir
    }
}
