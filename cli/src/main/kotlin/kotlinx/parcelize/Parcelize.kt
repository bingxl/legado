@file:Suppress("unused", "ClassName")

package kotlinx.parcelize

/**
 * JVM 侧替身：BookSource / SearchRule 等实体上的 @Parcelize 注解。
 * 桌面环境不做 Parcelable 代码生成，注解仅作占位以保持源码一致。
 */
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.CLASS)
annotation class Parcelize

@Retention(AnnotationRetention.SOURCE)
@Target(
    AnnotationTarget.FIELD,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.VALUE_PARAMETER
)
annotation class IgnoredOnParcel
