package io.legado.app.data.entities

import cn.hutool.crypto.symmetric.AES
import com.script.ScriptBindings
import com.script.buildScriptBindings
import com.script.rhino.RhinoScriptEngine
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppLog
import io.legado.app.help.CacheManager
import io.legado.app.help.JsExtensions
import io.legado.app.help.config.AppConfig
import io.legado.app.help.http.CookieStore
import io.legado.app.help.source.getShareScope
import io.legado.app.utils.GSON
import io.legado.app.utils.GSONStrict
import io.legado.app.utils.fromJsonObject
import io.legado.app.utils.has
import io.legado.app.utils.printOnDebug

/**
 * 可在 js 里调用, source.xxx()
 * 与 App 同名同签名，桌面端把 AES 登录信息加密简化为可逆存储。
 */
@Suppress("unused")
interface BaseSource : JsExtensions {

    var concurrentRate: String?
    var loginUrl: String?
    var loginUi: String?
    var header: String?
    var enabledCookieJar: Boolean?
    var jsLib: String?

    fun getTag(): String

    fun getKey(): String

    override fun getSource(): BaseSource? = this

    fun getLoginJs(): String? {
        val loginJs = loginUrl
        return when {
            loginJs == null -> null
            loginJs.startsWith("@js:") -> loginJs.substring(4)
            loginJs.startsWith("<js>") -> loginJs.substring(4, loginJs.lastIndexOf("<"))
            else -> loginJs
        }
    }

    fun login() {
        val loginJs = getLoginJs()
        if (!loginJs.isNullOrBlank()) {
            val js = """$loginJs
                if(typeof login=='function'){
                    login.apply(this);
                } else {
                    throw('Function login not implements!!!')
                }
            """.trimIndent()
            evalJS(js)
        }
    }

    fun getHeaderMap(hasLoginHeader: Boolean = false) = HashMap<String, String>().apply {
        header?.let {
            try {
                val json = when {
                    it.startsWith("@js:", true) -> evalJS(it.substring(4)).toString()
                    it.startsWith("<js>", true) -> evalJS(
                        it.substring(4, it.lastIndexOf("<"))
                    ).toString()

                    else -> it
                }
                GSONStrict.fromJsonObject<Map<String, String>>(json).getOrNull()?.let { map ->
                    putAll(map)
                } ?: GSON.fromJsonObject<Map<String, String>>(json).getOrNull()?.let { map ->
                    log("请求头规则 JSON 格式不规范，请改为规范格式")
                    putAll(map)
                }
            } catch (e: Exception) {
                AppLog.put("执行请求头规则出错\n$e", e)
            }
        }
        if (!has(AppConst.UA_NAME, true)) {
            put(AppConst.UA_NAME, AppConfig.userAgent)
        }
        if (hasLoginHeader) {
            getLoginHeaderMap()?.let { putAll(it) }
        }
    }

    fun getLoginHeader(): String? {
        return CacheManager.get("loginHeader_${getKey()}")
    }

    fun getLoginHeaderMap(): Map<String, String>? {
        val cache = getLoginHeader() ?: return null
        return GSON.fromJsonObject<Map<String, String>>(cache).getOrNull()
    }

    fun putLoginHeader(header: String) {
        val headerMap = GSON.fromJsonObject<Map<String, String>>(header).getOrNull()
        val cookie = headerMap?.get("Cookie") ?: headerMap?.get("cookie")
        cookie?.let { CookieStore.replaceCookie(getKey(), it) }
        CacheManager.put("loginHeader_${getKey()}", header)
    }

    fun removeLoginHeader() {
        CacheManager.delete("loginHeader_${getKey()}")
        CookieStore.removeCookie(getKey())
    }

    /**
     * 登录信息：App 内用 AES 加密存储，桌面端同样加密（密钥取 AppConst.androidId 前 16 字节）
     */
    fun getLoginInfo(): String? {
        return try {
            val key = AppConst.androidId.encodeToByteArray(0, 16)
            val cache = CacheManager.get("userInfo_${getKey()}") ?: return null
            AES(key).decryptStr(cache)
        } catch (e: Exception) {
            AppLog.put("获取登陆信息出错", e)
            null
        }
    }

    fun getLoginInfoMap(): Map<String, String>? {
        return GSON.fromJsonObject<Map<String, String>>(getLoginInfo()).getOrNull()
    }

    fun putLoginInfo(info: String): Boolean {
        return try {
            val key = AppConst.androidId.encodeToByteArray(0, 16)
            CacheManager.put("userInfo_${getKey()}", AES(key).encryptBase64(info))
            true
        } catch (e: Exception) {
            AppLog.put("保存登陆信息出错", e)
            false
        }
    }

    fun removeLoginInfo() {
        CacheManager.delete("userInfo_${getKey()}")
    }

    fun setVariable(variable: String?) {
        if (variable != null) {
            CacheManager.put("sourceVariable_${getKey()}", variable)
        } else {
            CacheManager.delete("sourceVariable_${getKey()}")
        }
    }

    fun getVariable(): String {
        return CacheManager.get("sourceVariable_${getKey()}") ?: ""
    }

    fun put(key: String, value: String): String {
        CacheManager.put("v_${getKey()}_${key}", value)
        return value
    }

    fun get(key: String): String {
        return CacheManager.get("v_${getKey()}_${key}") ?: ""
    }

    fun evalJS(jsStr: String, bindingsConfig: ScriptBindings.() -> Unit = {}): Any? {
        val bindings = buildScriptBindings { bindings ->
            bindings["java"] = this
            bindings["source"] = this
            bindings["baseUrl"] = getKey()
            bindings["cookie"] = CookieStore
            bindings["cache"] = CacheManager
            bindings.apply(bindingsConfig)
        }
        val sharedScope = getShareScope()
        val scope = if (sharedScope == null) {
            RhinoScriptEngine.getRuntimeScope(bindings)
        } else {
            bindings.apply { prototype = sharedScope }
        }
        return RhinoScriptEngine.eval(jsStr, scope)
    }
}
