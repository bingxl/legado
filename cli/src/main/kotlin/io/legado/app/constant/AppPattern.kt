package io.legado.app.constant

import java.util.regex.Pattern

/**
 * 与 App 保持一致的正则常量，直接决定规则切分行为，不能随意简化。
 */
@Suppress("RegExpRedundantEscape", "unused")
object AppPattern {

    val JS_PATTERN: Pattern =
        Pattern.compile("<js>([\\w\\W]*?)</js>|@js:([\\w\\W]*)", Pattern.CASE_INSENSITIVE)

    val EXP_PATTERN: Pattern = Pattern.compile("\\{\\{([\\w\\W]*?)\\}\\}")

    val imgPattern: Pattern =
        Pattern.compile("<img[^>]*src=['\"]([^'\"]*(?:['\"][^>]+\\})?)['\"][^>]*>")

    val dataUriRegex = Regex("^data:.*?;base64,(.*)")

    val nameRegex = Regex("\\s+作\\s*者.*|\\s+\\S+\\s+著")
    val authorRegex = Regex("^\\s*作\\s*者[:：\\s]+|\\s+著")
    val fileNameRegex = Regex("[\\\\/:*?\"<>|.]")
    val fileNameRegex2 = Regex("[\\\\/:*?\"<>|]")
    val splitGroupRegex = Regex("[,;，；]")
    val titleNumPattern: Pattern = Pattern.compile("(第)(.+?)(章)")

    val debugMessageSymbolRegex = Regex("[⇒◇┌└≡]")

    val bookFileRegex = Regex(".*\\.(txt|epub|umd|pdf|mobi|azw3|azw)", RegexOption.IGNORE_CASE)
    val archiveFileRegex = Regex(".*\\.(zip|rar|7z)$", RegexOption.IGNORE_CASE)

    val bdRegex = Regex("(\\p{P})+")
    val rnRegex = Regex("[\\r\\n]")
    val notReadAloudRegex = Regex("^(\\s|\\p{C}|\\p{P}|\\p{Z}|\\p{S})+$")

    val xmlContentTypeRegex = "(application|text)/\\w*\\+?xml.*".toRegex()
    val semicolonRegex = ";".toRegex()
    val equalsRegex = "=".toRegex()
    val spaceRegex = "\\s+".toRegex()
    val regexCharRegex = "[{}()\\[\\].+*?^$\\\\|]".toRegex()
    val LFRegex = "\n".toRegex()
}
