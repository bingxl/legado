@file:Suppress("unused")

package android.os

/**
 * JVM 侧替身：legado 的 rhino 包装用 Build.VERSION.SDK_INT 判断是否启用
 * 某些 Java 8+ 的类名放行规则。桌面 JVM 固定按高版本处理即可。
 */
object Build {

    object VERSION {
        const val SDK_INT: Int = 34
    }

    object VERSION_CODES {
        const val O: Int = 26
    }
}
