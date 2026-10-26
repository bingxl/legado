package io.legado.app.help

/**
 * 大文本变量（正文级的变量会超过 1 万字符），App 里落库，桌面端放内存。
 * 键与 App 保持一致，保证同一书源脚本的行为不因存储不同而改变。
 */
object RuleBigDataHelp {

    private val store = HashMap<String, String>()

    fun putBookVariable(bookUrl: String, key: String, value: String?) {
        put("book_${bookUrl}_$key", value)
    }

    fun getBookVariable(bookUrl: String, key: String): String? = store["book_${bookUrl}_$key"]

    fun putChapterVariable(bookUrl: String, chapterUrl: String, key: String, value: String?) {
        put("chapter_${bookUrl}_${chapterUrl}_$key", value)
    }

    fun getChapterVariable(bookUrl: String, chapterUrl: String, key: String): String? =
        store["chapter_${bookUrl}_${chapterUrl}_$key"]

    private fun put(key: String, value: String?) {
        if (value == null) store.remove(key) else store[key] = value
    }
}
