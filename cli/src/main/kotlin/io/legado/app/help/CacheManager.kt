package io.legado.app.help

import io.legado.app.help.config.CliStorage
import io.legado.app.utils.GSON

/**
 * 键值缓存：App 里落 Room，桌面端放内存 + 一个 JSON 文件，
 * 保证 Cookie 之外的源变量、登录信息在多次运行间可复用。
 */
object CacheManager {

    private data class Entry(val value: String, val deadline: Long)

    private val memory = LinkedHashMap<String, Entry>()

    private val file by lazy { CliStorage.cacheFile("kv-cache.json") }

    private var loaded = false

    @Synchronized
    private fun load() {
        if (loaded) return
        loaded = true
        kotlin.runCatching {
            if (file.exists()) {
                val map = GSON.fromJson(file.readText(), HashMap::class.java) ?: return
                map.forEach { (k, v) ->
                    val entry = GSON.fromJson(GSON.toJson(v), Entry::class.java) ?: return@forEach
                    memory[k.toString()] = entry
                }
            }
        }
    }

    @Synchronized
    fun put(key: String, value: Any, saveTime: Int = 0) {
        load()
        val deadline = if (saveTime > 0) System.currentTimeMillis() + saveTime * 1000L else 0L
        memory[key] = Entry(value.toString(), deadline)
        flush()
    }

    @Synchronized
    fun putMemory(key: String, value: Any) {
        load()
        memory[key] = Entry(value.toString(), 0)
    }

    @Synchronized
    fun getFromMemory(key: String): Any? {
        load()
        val entry = memory[key] ?: return null
        if (entry.deadline > 0 && entry.deadline < System.currentTimeMillis()) {
            memory.remove(key)
            return null
        }
        return entry.value
    }

    @Synchronized
    fun deleteMemory(key: String) {
        memory.remove(key)
    }

    @Synchronized
    fun get(key: String): String? = getFromMemory(key) as? String

    fun getInt(key: String): Int? = get(key)?.toIntOrNull()

    fun getLong(key: String): Long? = get(key)?.toLongOrNull()

    fun getDouble(key: String): Double? = get(key)?.toDoubleOrNull()

    fun getFloat(key: String): Float? = get(key)?.toFloatOrNull()

    fun getByteArray(key: String): ByteArray? = get(key)?.toByteArray()

    @Synchronized
    fun delete(key: String) {
        load()
        memory.remove(key)
        flush()
    }

    @Synchronized
    fun clearSourceVariables() {
        load()
        memory.keys.filter { it.startsWith("sourceVariable_") || it.startsWith("v_") }
            .forEach { memory.remove(it) }
        flush()
    }

    @Synchronized
    fun clearAll() {
        memory.clear()
        flush()
    }

    @Synchronized
    private fun flush() {
        kotlin.runCatching {
            file.parentFile?.mkdirs()
            file.writeText(GSON.toJson(memory))
        }
    }
}
