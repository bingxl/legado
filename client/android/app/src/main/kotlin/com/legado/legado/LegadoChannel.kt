package com.legado.legado

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * `legado/core` 通道：把 Dart 的调用转给 gomobile 绑定的 Go 运行时（AAR 内）。
 *
 * 契约（与 hosts/rt 的调用协议一致）：
 *  - `init`    {homeDir: String?, version: String?} -> null
 *  - `call`    {request: String} -> 响应信封 JSON 字符串
 *  - `methods` 无参 -> 方法表 JSON 字符串
 *
 * **为什么用反射调 `mobile.Mobile` 而不是直接 import**：
 * AAR 是 gomobile 的构建产物且不入库（`app/libs/*.aar` 已 gitignore）。
 * 若这里写死 `import mobile.Mobile`，没跑过 `gomobile bind` 的人连
 * `flutter build apk` 都过不了 Kotlin 编译——「没装 NDK 就出不了包」
 * 比「core 没接上」严重得多。反射换来的是：没有 AAR 也能出壳子包，
 * 调用时给一条明确的错误文案。代价只是失去编译期类型检查（三个方法，可控）。
 *
 * Go 侧调用是阻塞的（可能要抓网络），因此统一丢到单线程池执行，
 * 结果再 post 回主线程 —— MethodChannel 的 Result 必须在平台线程上回调。
 */
object LegadoChannel {
    private const val CHANNEL = "legado/core"
    private const val CORE_CLASS = "mobile.Mobile"

    private val io: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "legado-core").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    /** AAR 里的入口类；未接入时为 null。只解析一次。 */
    private val core: Class<*>? by lazy {
        runCatching { Class.forName(CORE_CLASS) }.getOrNull()
    }

    /** 未接入 AAR 时的统一提示。宁可提示得直白，也不要抛 ClassNotFoundException 堆栈。 */
    private fun missing(): Throwable = IllegalStateException(
        "未找到 gomobile 绑定（$CORE_CLASS）。请先执行 " +
            "scripts/build.ps1 -Target android，或按 hosts/README.md 的「Android（gomobile）」" +
            "一节手动 gomobile bind 生成 client/android/app/libs/legado.aar。"
    )

    fun register(messenger: BinaryMessenger, filesDir: String) {
        val channel = MethodChannel(messenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> runAsync(result) {
                    val cls = core ?: throw missing()
                    val home = call.stringArg("homeDir")?.takeIf { it.isNotBlank() } ?: filesDir
                    val version = call.stringArg("version") ?: ""
                    cls.getMethod("init", String::class.java, String::class.java)
                        .invoke(null, home, version)
                    null
                }

                "call" -> runAsync(result) {
                    val cls = core ?: throw missing()
                    val request = call.stringArg("request")
                        ?: throw IllegalArgumentException("缺少 request 参数")
                    cls.getMethod("call", String::class.java).invoke(null, request) as String
                }

                "methods" -> runAsync(result) {
                    val cls = core ?: throw missing()
                    cls.getMethod("methods").invoke(null) as String
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun MethodCall.stringArg(key: String): String? = argument<String>(key)

    private fun runAsync(result: MethodChannel.Result, block: () -> Any?) {
        io.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (t: Throwable) {
                // 反射调用会把 Go 返回的 error 包成 InvocationTargetException，
                // 取 cause 才是真正的原因，否则用户只能看到一串反射栈。
                val real = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
                val message = real.message ?: real.toString()
                main.post { result.error("MOBILE_ERROR", message, null) }
            }
        }
    }
}
