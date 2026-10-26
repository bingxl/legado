@file:Suppress("unused", "ClassName")

package androidx.annotation

@Retention(AnnotationRetention.SOURCE)
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.FIELD,
    AnnotationTarget.CONSTRUCTOR,
    AnnotationTarget.VALUE_PARAMETER,
    AnnotationTarget.LOCAL_VARIABLE,
    AnnotationTarget.FILE
)
annotation class SuppressLint(vararg val value: String)

@Retention(AnnotationRetention.SOURCE)
@Target(
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY_GETTER,
    AnnotationTarget.PROPERTY_SETTER,
    AnnotationTarget.VALUE_PARAMETER,
    AnnotationTarget.FIELD,
    AnnotationTarget.LOCAL_VARIABLE
)
annotation class IntDef(vararg val value: Int)

@Retention(AnnotationRetention.SOURCE)
annotation class NonNull

@Retention(AnnotationRetention.SOURCE)
annotation class Nullable
