@file:Suppress("unused", "ClassName")

package android.os

/**
 * JVM 侧替身：实体类上的 Parcelable 只是 Android 序列化标记，
 * 桌面环境保留类型占位（不做真正序列化），让 legado 源码无需改动即可编译。
 */
interface Parcelable
