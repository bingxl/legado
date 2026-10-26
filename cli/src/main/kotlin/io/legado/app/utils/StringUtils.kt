package io.legado.app.utils

import java.text.DecimalFormat

/**
 * 字符串工具：与 App 保持一致的少量实现
 */
@Suppress("unused")
object StringUtils {

    private val wordCountFormatter = DecimalFormat("0.##")

    fun isNumeric(str: String): Boolean = str.isNotEmpty() && str.all { it.isDigit() }

    fun wordCountFormat(words: Int): String {
        var wordsS = ""
        if (words > 0) {
            wordsS = if (words > 10000) {
                wordCountFormatter.format(words * 1.0f / 10000f.toDouble()) + "万字"
            } else {
                "$words" + "字"
            }
        }
        return wordsS
    }

    fun wordCountFormat(wc: String?): String {
        if (wc == null) return ""
        var wordsS = ""
        if (isNumeric(wc)) {
            wordsS = wordCountFormat(wc.toInt())
        } else {
            wordsS = wc
        }
        return wordsS
    }

    private val chineseNums = mapOf(
        '一' to 1, '二' to 2, '两' to 2, '三' to 3, '四' to 4, '五' to 5,
        '六' to 6, '七' to 7, '八' to 8, '九' to 9, '十' to 10,
        '百' to 100, '千' to 1000, '万' to 10000, '零' to 0
    )

    /**
     * 章节序号转数字：支持 "123"、"一百二十三" 两种写法
     */
    fun stringToInt(str: String): String {
        val trim = str.trim()
        if (trim.isEmpty()) return str
        if (trim.all { it.isDigit() }) return trim
        var result = 0
        var section = 0
        var number = 0
        for (c in trim) {
            val n = chineseNums[c] ?: return str
            when {
                n >= 10000 -> {
                    section = (section + number) * n
                    result += section
                    section = 0
                    number = 0
                }

                n >= 100 -> {
                    if (number == 0) number = 1
                    section += number * n
                    number = 0
                }

                else -> number = n
            }
        }
        return (result + section + number).toString()
    }
}
