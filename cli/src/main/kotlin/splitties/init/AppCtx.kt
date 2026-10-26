@file:Suppress("unused")

package splitties.init

import io.legado.app.R

/**
 * App 里到处用的全局 Context。桌面端没有 Context，
 * 这里提供同名入口，只实现引擎需要的 getString。
 */
object appCtx {

    private val strings = mapOf(
        R.string.error_get_web_content to "获取网页内容失败 %s",
        R.string.chapter_list_empty to "目录列表为空",
        R.string.intro_show_null to "暂无简介",
        R.string.intro_show to "简介：%s",
        R.string.no_books_dir to "请设置书籍保存文件夹",
        R.string.book_info_empty to "书籍信息为空",
        R.string.search_book_empty to "搜索结果为空"
    )

    fun getString(resId: Int): String = strings[resId] ?: ""

    fun getString(resId: Int, vararg formatArgs: Any): String {
        val template = strings[resId] ?: return formatArgs.joinToString(" ")
        return try {
            String.format(template, *formatArgs)
        } catch (e: Exception) {
            template
        }
    }
}
