@file:Suppress("unused", "ClassName")

package android.view

/**
 * JVM 侧替身：只有 FlexChildStyle 的样式应用逻辑会用到 View，
 * 桌面端不做 UI，因此只保留类型与 layoutParams 入口。
 */
open class View {
    open val layoutParams: Any? = null
}
