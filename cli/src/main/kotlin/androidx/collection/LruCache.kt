@file:Suppress("unused")

package androidx.collection

/**
 * JVM 侧替身：legado 的类名匹配缓存只用到 get/put，
 * 用 LinkedHashMap 实现同样的 LRU 行为，避免引入 AndroidX。
 */
class LruCache<K, V>(private val maxSize: Int) {

    private val map = object : LinkedHashMap<K, V>(maxSize, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean {
            return size > maxSize
        }
    }

    @Synchronized
    operator fun get(key: K): V? = map[key]

    @Synchronized
    fun put(key: K, value: V): V? = map.put(key, value)

    @Synchronized
    fun remove(key: K): V? = map.remove(key)

    @Synchronized
    fun evictAll() = map.clear()
}
