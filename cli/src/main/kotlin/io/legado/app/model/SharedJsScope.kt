package io.legado.app.model

import com.google.gson.reflect.TypeToken
import com.script.ScriptBindings
import com.script.rhino.RhinoScriptEngine
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.config.CliStorage
import io.legado.app.help.http.newCallStrResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.utils.GSON
import io.legado.app.utils.MD5Utils
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.isJsonObject
import kotlinx.coroutines.runBlocking
import org.mozilla.javascript.Scriptable
import org.mozilla.javascript.ScriptableObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.CoroutineContext

/**
 * 书源 jsLib 的共享作用域：同一份 jsLib 只编译一次，供所有规则复用。
 * 与 App 行为一致，只是把 ACache 换成本地文件缓存。
 */
object SharedJsScope {

    private val cacheFolder by lazy { File(CliStorage.cacheDir, "shareJs").apply { mkdirs() } }

    private val scopeMap = ConcurrentHashMap<String, WeakReference<Scriptable>>()

    fun getScope(jsLib: String?, coroutineContext: CoroutineContext?): Scriptable? {
        if (jsLib.isNullOrBlank()) return null
        val key = MD5Utils.md5Encode(jsLib)
        var scope = scopeMap[key]?.get()
        if (scope == null) {
            scope = RhinoScriptEngine.getRuntimeScope(ScriptBindings())
            if (jsLib.isJsonObject()) {
                val jsMap: Map<String, String> = GSON.fromJson(
                    jsLib,
                    TypeToken.getParameterized(
                        Map::class.java,
                        String::class.java,
                        String::class.java
                    ).type
                )
                jsMap.values.forEach { value ->
                    if (value.isAbsUrl()) {
                        val fileName = MD5Utils.md5Encode(value)
                        val cacheFile = File(cacheFolder, fileName)
                        val js = if (cacheFile.exists()) {
                            cacheFile.readText()
                        } else {
                            val body = runBlocking {
                                okHttpClient.newCallStrResponse { url(value) }.body
                            } ?: throw NoStackTraceException("下载jsLib-${value}失败")
                            cacheFile.writeText(body)
                            body
                        }
                        RhinoScriptEngine.eval(js, scope, coroutineContext)
                    }
                }
            } else {
                RhinoScriptEngine.eval(jsLib, scope, coroutineContext)
            }
            if (scope is ScriptableObject) scope.sealObject()
            scopeMap[key] = WeakReference(scope)
        }
        return scope
    }

    fun remove(jsLib: String?) {
        if (jsLib.isNullOrBlank()) return
        scopeMap.remove(MD5Utils.md5Encode(jsLib))
    }
}
