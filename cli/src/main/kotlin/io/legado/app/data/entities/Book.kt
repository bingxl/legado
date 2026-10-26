package io.legado.app.data.entities

import io.legado.app.constant.AppPattern
import io.legado.app.constant.BookType
import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.utils.GSON
import io.legado.app.utils.fromJsonObject

/**
 * 书籍实体（桌面端裁剪版）：去掉 Room / Parcelize / ReadConfig，
 * 字段与 App 保持一致，保证书源脚本里的 book.xxx 取值不变。
 */
data class Book(
    override var bookUrl: String = "",
    var tocUrl: String = "",
    var origin: String = BookType.localTag,
    var originName: String = "",
    override var name: String = "",
    override var author: String = "",
    override var kind: String? = null,
    var customTag: String? = null,
    var coverUrl: String? = null,
    var customCoverUrl: String? = null,
    var intro: String? = null,
    var customIntro: String? = null,
    var charset: String? = null,
    var type: Int = BookType.text,
    var group: Long = 0,
    var latestChapterTitle: String? = null,
    var latestChapterTime: Long = System.currentTimeMillis(),
    var lastCheckTime: Long = System.currentTimeMillis(),
    var lastCheckCount: Int = 0,
    var totalChapterNum: Int = 0,
    var durChapterTitle: String? = null,
    var durChapterIndex: Int = 0,
    var durChapterPos: Int = 0,
    var durChapterTime: Long = System.currentTimeMillis(),
    override var wordCount: String? = null,
    var canUpdate: Boolean = true,
    var order: Int = 0,
    var originOrder: Int = 0,
    override var variable: String? = null,
    var syncTime: Long = 0L,
    // 注意：桌面端没有 ReadConfig，用普通字段承载；
    // 为避开 JVM 签名冲突（getReverseToc()Z 等），字段名加 Config 后缀，
    // 对外仍暴露上游代码调用的 getReverseToc()/setReverseToc() 等方法。
    var reverseTocConfig: Boolean = false,
    var useReplaceRuleConfig: Boolean = true
) : BaseBook {

    override var infoHtml: String? = null
    override var tocHtml: String? = null

    var downloadUrls: List<String>? = null

    override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: hashMapOf()
    }

    override fun putVariable(key: String, value: String?): Boolean {
        if (super.putVariable(key, value)) {
            variable = GSON.toJson(variableMap)
        }
        return true
    }

    override fun equals(other: Any?): Boolean {
        if (other is Book) {
            return other.bookUrl == bookUrl
        }
        return false
    }

    override fun hashCode(): Int = bookUrl.hashCode()

    val lastChapterIndex get() = totalChapterNum - 1

    fun getRealAuthor() = author.replace(AppPattern.authorRegex, "")

    fun getDisplayCover() = if (customCoverUrl.isNullOrEmpty()) coverUrl else customCoverUrl

    fun getDisplayIntro() = if (customIntro.isNullOrEmpty()) intro else customIntro

    fun setReverseToc(reverseToc: Boolean) {
        this.reverseTocConfig = reverseToc
    }

    fun getReverseToc(): Boolean = reverseTocConfig

    fun setUseReplaceRule(useReplaceRule: Boolean) {
        this.useReplaceRuleConfig = useReplaceRule
    }

    fun getUseReplaceRule(): Boolean = useReplaceRuleConfig

    fun releaseHtmlData() {
        infoHtml = null
        tocHtml = null
    }

    fun toSearchBook() = SearchBook(
        name = name,
        author = author,
        kind = kind,
        bookUrl = bookUrl,
        origin = origin,
        originName = originName,
        type = type,
        wordCount = wordCount,
        latestChapterTitle = latestChapterTitle,
        coverUrl = coverUrl,
        intro = intro,
        tocUrl = tocUrl,
        originOrder = originOrder,
        variable = variable
    ).apply {
        this.infoHtml = this@Book.infoHtml
        this.tocHtml = this@Book.tocHtml
    }
}

private typealias RuleDataInterfaceRef = RuleDataInterface
