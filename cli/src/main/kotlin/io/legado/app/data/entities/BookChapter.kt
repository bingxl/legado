package io.legado.app.data.entities

import io.legado.app.constant.AppPattern
import io.legado.app.help.RuleBigDataHelp
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.utils.GSON
import io.legado.app.utils.fromJsonObject

data class BookChapter(
    var url: String = "",
    var title: String = "",
    var isVolume: Boolean = false,
    var baseUrl: String = "",
    var bookUrl: String = "",
    var index: Int = 0,
    var isVip: Boolean = false,
    var isPay: Boolean = false,
    var resourceUrl: String? = null,
    var tag: String? = null,
    var wordCount: String? = null,
    var start: Long? = null,
    var end: Long? = null,
    var startFragmentId: String? = null,
    var endFragmentId: String? = null,
    var variable: String? = null
) : RuleDataInterface {

    override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: hashMapOf()
    }

    override fun putVariable(key: String, value: String?): Boolean {
        if (super.putVariable(key, value)) {
            variable = GSON.toJson(variableMap)
        }
        return true
    }

    override fun putBigVariable(key: String, value: String?) {
        RuleBigDataHelp.putChapterVariable(bookUrl, url, key, value)
    }

    override fun getBigVariable(key: String): String? {
        return RuleBigDataHelp.getChapterVariable(bookUrl, url, key)
    }

    var titleMD5: String? = null

    fun primaryStr(): String = bookUrl + url

    fun getAbsoluteURL(): String {
        if (url.startsWith(title) && isVolume) return baseUrl
        val urlMatcher = io.legado.app.model.analyzeRule.AnalyzeUrl.paramPattern.matcher(url)
        val urlBefore = if (urlMatcher.find()) url.substring(0, urlMatcher.start()) else url
        val urlAbsoluteBefore = io.legado.app.utils.NetworkUtils.getAbsoluteURL(baseUrl, urlBefore)
        return if (urlBefore.length == url.length) {
            urlAbsoluteBefore
        } else {
            "$urlAbsoluteBefore," + url.substring(urlMatcher.end())
        }
    }

    private fun ensureTitleMD5Init() {
        if (titleMD5 == null) titleMD5 = io.legado.app.utils.MD5Utils.md5Encode16(title)
    }

    fun getFileName(suffix: String = "nb"): String {
        ensureTitleMD5Init()
        return String.format("%05d-%s.%s", index, titleMD5, suffix)
    }

    fun getFontName(): String {
        ensureTitleMD5Init()
        return String.format("%05d-%s.ttf", index, titleMD5)
    }

    /**
     * 展示用章节标题：去掉换行，按需套用替换规则（CLI 默认无替换规则）
     */
    fun getDisplayTitle(
        replaceRules: List<ReplaceRule>? = null,
        useReplace: Boolean = true,
        chineseConvert: Boolean = true
    ): String {
        var displayTitle = title.replace(AppPattern.rnRegex, "")
        if (useReplace && replaceRules != null) {
            replaceRules.forEach { item ->
                if (item.pattern.isNotEmpty()) {
                    try {
                        displayTitle = if (item.isRegex) {
                            item.regex.replace(displayTitle, item.replacement)
                        } else {
                            displayTitle.replace(item.pattern, item.replacement)
                        }
                    } catch (ignore: Exception) {
                    }
                }
            }
        }
        return displayTitle
    }
}
