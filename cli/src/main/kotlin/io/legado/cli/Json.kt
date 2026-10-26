package io.legado.cli

import com.google.gson.ExclusionStrategy
import com.google.gson.FieldAttributes
import com.google.gson.Gson
import io.legado.app.utils.GSON

/**
 * CLI 专用 Gson：排除 `by lazy` 生成的 `xxx$delegate` 字段。
 *
 * 书源实体里的 variableMap / origins 都是懒加载缓存，写盘时不该出现，
 * 读回时也无法反序列化（Lazy 没有无参构造），所以在序列化层屏蔽掉。
 */
private object LazyDelegateExclusion : ExclusionStrategy {
    override fun shouldSkipField(f: FieldAttributes): Boolean = f.name.endsWith("\$delegate")
    override fun shouldSkipClass(clazz: Class<*>): Boolean = false
}

val CLI_GSON: Gson by lazy {
    GSON.newBuilder()
        .addSerializationExclusionStrategy(LazyDelegateExclusion)
        .addDeserializationExclusionStrategy(LazyDelegateExclusion)
        .create()
}
