package io.legado.app.data.entities

import io.legado.app.model.analyzeRule.RuleDataInterface
import io.legado.app.utils.GSON
import io.legado.app.utils.fromJsonObject

/**
 * RSS 文章：AnalyzeRule 允许 ruleData 是 RssArticle（RSS 源规则）。
 * CLI 只做书源，保留该类型仅为编译兼容与 RSS 规则的可扩展性。
 */
data class RssArticle(
    var origin: String = "",
    var sort: String = "",
    var title: String = "",
    var link: String = "",
    var pubDate: String? = null,
    var description: String? = null,
    var content: String? = null,
    var image: String? = null,
    var read: Boolean = false,
    var star: Boolean = false,
    var variable: String? = null
) : RuleDataInterface {

    override val variableMap: HashMap<String, String> by lazy {
        GSON.fromJsonObject<HashMap<String, String>>(variable).getOrNull() ?: hashMapOf()
    }

    override fun putBigVariable(key: String, value: String?) = Unit

    override fun getBigVariable(key: String): String? = null
}
