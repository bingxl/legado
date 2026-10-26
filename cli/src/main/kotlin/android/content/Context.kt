@file:Suppress("unused")

package android.content

/**
 * JVM 侧替身：legado 的脚本沙箱会把 android.content.Context 列入禁止反射的类，
 * 桌面环境下只需一个同名空类占位，保证黑名单判断逻辑原样运行。
 */
open class Context
