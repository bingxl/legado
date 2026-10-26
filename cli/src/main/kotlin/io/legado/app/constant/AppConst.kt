package io.legado.app.constant

import org.apache.commons.lang3.time.FastDateFormat

/**
 * CLI 侧常量：只保留引擎用到的部分，取值与 App 保持一致。
 */
@Suppress("ConstPropertyName", "unused")
object AppConst {

    const val APP_TAG = "Legado"

    const val UA_NAME = "User-Agent"

    const val MAX_THREAD = 9

    const val DEFAULT_USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    val timeFormat: FastDateFormat by lazy { FastDateFormat.getInstance("HH:mm") }

    val dateFormat: FastDateFormat by lazy { FastDateFormat.getInstance("yyyy/MM/dd HH:mm") }

    val fileNameFormat: FastDateFormat by lazy { FastDateFormat.getInstance("yy-MM-dd-HH-mm-ss") }

    /**
     * App 里取的是 Android ID，桌面端用固定值即可（仅用于登录信息加密的盐）
     */
    val androidId: String by lazy { "legado-cli-000000" }
}
