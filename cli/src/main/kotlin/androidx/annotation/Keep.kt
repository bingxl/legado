@file:Suppress("unused", "ClassName")

package androidx.annotation

/**
 * JVM 侧替身：仅用于让 legado 源码中的 @Keep 注解在桌面 JVM 上编译通过。
 * 该注解在 App 中只影响 ProGuard/R8 保留，JVM 上没有语义。
 */
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.FIELD,
    AnnotationTarget.CONSTRUCTOR
)
annotation class Keep
