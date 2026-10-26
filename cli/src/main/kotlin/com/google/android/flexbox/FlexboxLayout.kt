@file:Suppress("unused", "ClassName")

package com.google.android.flexbox

/**
 * JVM 侧替身：发现分类的样式只影响 App 里的标签布局，
 * 桌面端保留同名结构与可写属性，保证 FlexChildStyle 源码可原样编译。
 */
class FlexboxLayout {

    class LayoutParams {
        var flexGrow: Float = 0f
        var flexShrink: Float = 1f
        var alignSelf: Int = -1
        var flexBasisPercent: Float = -1f
        var isWrapBefore: Boolean = false
    }
}
