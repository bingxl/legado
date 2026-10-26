package io.legado.app.utils

import kotlinx.coroutines.async
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.sync.Semaphore
import java.util.regex.Pattern

/**
 * 字符串/集合扩展：与 App 同名同语义，供规则引擎直接调用。
 */

fun String.isAbsUrl(): Boolean {
    return startsWith("http://", true) || startsWith("https://", true)
}

fun String.isDataUrl(): Boolean = startsWith("data:", true)

fun String.isJson(): Boolean = isJsonObject() || isJsonArray()

fun String.isJsonObject(): Boolean {
    val trim = trim()
    return trim.startsWith("{") && trim.endsWith("}")
}

fun String.isJsonArray(): Boolean {
    val trim = trim()
    return trim.startsWith("[") && trim.endsWith("]")
}

fun String.isXml(): Boolean {
    val trim = trimStart()
    return trim.startsWith("<?xml") || (trim.startsWith("<") && !trim.startsWith("<!doctype", true) && isXmlLike())
}

private fun String.isXmlLike(): Boolean = contains("</") && !contains("<html", true)

fun String.isTrue(): Boolean = equals("true", true)

fun String.isFalse(): Boolean = equals("false", true)

fun String.splitNotBlank(vararg delimiter: String, limit: Int = 0): Array<String> {
    return this.split(*delimiter, limit = limit).map { it.trim() }.filterNot { it.isBlank() }
        .toTypedArray()
}

fun String.splitNotBlank(regex: Regex, limit: Int = 0): Array<String> {
    return this.split(regex, limit).map { it.trim() }.filterNot { it.isBlank() }.toTypedArray()
}

fun String.escapeRegex(): String = Pattern.quote(this)

val Throwable.stackTraceStr: String
    get() {
        val stackTrace = stackTraceToString()
        val lMsg = this.localizedMessage ?: "noErrorMsg"
        return if (stackTrace.isNotEmpty()) stackTrace else lMsg
    }

fun Throwable.printOnDebug() {
    if (io.legado.app.model.Debug.verbose) printStackTrace()
}

fun <T> Result<T>.printOnDebug(): Result<T> {
    exceptionOrNull()?.printOnDebug()
    return this
}

fun <T> HashMap<String, T>.get(key: String, ignoreCase: Boolean = false): T? {
    if (!ignoreCase) return get(key as String)
    @Suppress("UNCHECKED_CAST")
    val entry = entries.firstOrNull { it.key.equals(key, true) } ?: return null
    return entry.value
}

fun Map<String, String>.has(key: String, ignoreCase: Boolean = false): Boolean {
    if (ignoreCase) {
        return keys.any { it.equals(key, true) }
    }
    return containsKey(key)
}

inline fun <K, V> MutableMap<K, V>.getOrPutLimit(key: K, maxSize: Int, defaultValue: () -> V): V {
    if (containsKey(key)) {
        @Suppress("UNCHECKED_CAST")
        return get(key) as V
    }
    val value = defaultValue()
    if (size < maxSize) {
        put(key, value)
    } else {
        remove(keys.first())
        put(key, value)
    }
    return value
}

/**
 * 并发处理 Flow，用于目录/正文分页的并发抓取
 */
inline fun <T, R> Flow<T>.mapAsync(
    concurrency: Int,
    crossinline transform: suspend (T) -> R
): Flow<R> = if (concurrency <= 1) {
    map { transform(it) }
} else {
    val semaphore = Semaphore(concurrency)
    channelFlow {
        collect {
            semaphore.acquire()
            send(async { transform(it) })
        }
    }.map {
        it.await()
    }.onEach { semaphore.release() }
}

/**
 * 线程安全的并发 map，保持顺序
 */
suspend fun <T, R> Iterable<T>.mapParallelSafe(
    concurrency: Int,
    transform: suspend (T) -> R
): List<R> = kotlinx.coroutines.coroutineScope {
    val semaphore = Semaphore(concurrency.coerceAtLeast(1))
    map { item ->
        async {
            semaphore.acquire()
            try {
                transform(item)
            } finally {
                semaphore.release()
            }
        }
    }.map { it.await() }
}

/**
 * 字符串按码点拆分（emoji 等多字节字符也能正确拆）
 */
fun String.toStringArray(): Array<String> {
    val array = ArrayList<String>(length)
    var i = 0
    while (i < length) {
        val codePoint = codePointAt(i)
        val count = Character.charCount(codePoint)
        array.add(substring(i, i + count))
        i += count
    }
    return array.toTypedArray()
}
