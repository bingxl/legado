package io.legado.app.data.entities

import io.legado.app.constant.AppPattern
import io.legado.app.constant.BookSourceType
import io.legado.app.data.appDb
import io.legado.app.data.entities.rule.BookInfoRule
import io.legado.app.data.entities.rule.ContentRule
import io.legado.app.data.entities.rule.ExploreRule
import io.legado.app.data.entities.rule.ReviewRule
import io.legado.app.data.entities.rule.SearchRule
import io.legado.app.data.entities.rule.TocRule
import io.legado.app.utils.GSON
import io.legado.app.utils.splitNotBlank

/**
 * 书源实体（桌面端裁剪版）：字段与 App 完全一致，直接对应书源 JSON 的键名，
 * 去掉 Room/Parcelize 注解以便在纯 JVM 上反序列化。
 */
data class BookSource(
    var bookSourceUrl: String = "",
    var bookSourceName: String = "",
    var bookSourceGroup: String? = null,
    @BookSourceType.Type
    var bookSourceType: Int = 0,
    var bookUrlPattern: String? = null,
    var customOrder: Int = 0,
    var enabled: Boolean = true,
    var enabledExplore: Boolean = true,
    override var jsLib: String? = null,
    override var enabledCookieJar: Boolean? = true,
    override var concurrentRate: String? = null,
    override var header: String? = null,
    override var loginUrl: String? = null,
    override var loginUi: String? = null,
    var loginCheckJs: String? = null,
    var coverDecodeJs: String? = null,
    var bookSourceComment: String? = null,
    var variableComment: String? = null,
    var lastUpdateTime: Long = 0,
    var respondTime: Long = 180000L,
    var weight: Int = 0,
    var exploreUrl: String? = null,
    var exploreScreen: String? = null,
    var ruleExplore: ExploreRule? = null,
    var searchUrl: String? = null,
    var ruleSearch: SearchRule? = null,
    var ruleBookInfo: BookInfoRule? = null,
    var ruleToc: TocRule? = null,
    var ruleContent: ContentRule? = null,
    var ruleReview: ReviewRule? = null
) : BaseSource {

    override fun getTag(): String = bookSourceName

    override fun getKey(): String = bookSourceUrl

    override fun hashCode(): Int = bookSourceUrl.hashCode()

    override fun equals(other: Any?): Boolean {
        return if (other is BookSource) other.bookSourceUrl == bookSourceUrl else false
    }

    fun getSearchRule(): SearchRule {
        ruleSearch?.let { return it }
        val rule = SearchRule()
        ruleSearch = rule
        return rule
    }

    fun getExploreRule(): ExploreRule {
        ruleExplore?.let { return it }
        val rule = ExploreRule()
        ruleExplore = rule
        return rule
    }

    fun getBookInfoRule(): BookInfoRule {
        ruleBookInfo?.let { return it }
        val rule = BookInfoRule()
        ruleBookInfo = rule
        return rule
    }

    fun getTocRule(): TocRule {
        ruleToc?.let { return it }
        val rule = TocRule()
        ruleToc = rule
        return rule
    }

    fun getContentRule(): ContentRule {
        ruleContent?.let { return it }
        val rule = ContentRule()
        ruleContent = rule
        return rule
    }

    fun getDisPlayNameGroup(): String {
        return if (bookSourceGroup.isNullOrBlank()) {
            bookSourceName
        } else {
            String.format("%s (%s)", bookSourceName, bookSourceGroup)
        }
    }

    fun addGroup(groups: String): BookSource {
        bookSourceGroup?.splitNotBlank(AppPattern.splitGroupRegex)?.toHashSet()?.let {
            it.addAll(groups.splitNotBlank(AppPattern.splitGroupRegex))
            bookSourceGroup = it.joinToString(",")
        }
        if (bookSourceGroup.isNullOrBlank()) bookSourceGroup = groups
        return this
    }

    fun hasGroup(group: String): Boolean {
        bookSourceGroup?.splitNotBlank(AppPattern.splitGroupRegex)?.toHashSet()?.let {
            return it.indexOf(group) != -1
        }
        return false
    }

    fun getCheckKeyword(default: String): String {
        ruleSearch?.checkKeyWord?.let { if (it.isNotBlank()) return it }
        return default
    }

    fun getDisplayVariableComment(otherComment: String): String {
        return if (variableComment.isNullOrBlank()) {
            otherComment
        } else {
            "${variableComment}\n$otherComment"
        }
    }

    /**
     * 书源是否匹配某个书籍详情页地址
     */
    fun getBookSourcePart() = BookSourcePart(
        bookSourceUrl = bookSourceUrl,
        bookSourceName = bookSourceName,
        bookSourceGroup = bookSourceGroup,
        customOrder = customOrder,
        enabled = enabled,
        enabledExplore = enabledExplore,
        hasLoginUrl = !loginUrl.isNullOrBlank(),
        lastUpdateTime = lastUpdateTime,
        respondTime = respondTime,
        weight = weight,
        hasExploreUrl = !exploreUrl.isNullOrBlank()
    )

    companion object {
        fun fromJson(json: String): BookSource? {
            return GSON.fromJson(json, BookSource::class.java)
        }
    }
}

/**
 * 书源列表视图（App 里是 Room 的 DatabaseView），桌面端只是投影
 */
data class BookSourcePart(
    var bookSourceUrl: String = "",
    var bookSourceName: String = "",
    var bookSourceGroup: String? = null,
    var customOrder: Int = 0,
    var enabled: Boolean = true,
    var enabledExplore: Boolean = true,
    var hasLoginUrl: Boolean = false,
    var lastUpdateTime: Long = 0,
    var respondTime: Long = 180000L,
    var weight: Int = 0,
    var hasExploreUrl: Boolean = false
) {

    override fun hashCode(): Int = bookSourceUrl.hashCode()

    override fun equals(other: Any?): Boolean {
        return if (other is BookSourcePart) other.bookSourceUrl == bookSourceUrl else false
    }

    fun getDisPlayNameGroup(): String {
        return if (bookSourceGroup.isNullOrBlank()) {
            bookSourceName
        } else {
            String.format("%s (%s)", bookSourceName, bookSourceGroup)
        }
    }

    fun getBookSource(): BookSource? = appDb.bookSourceDao.getBookSource(bookSourceUrl)
}
