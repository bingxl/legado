package io.legado.app.help.http

import io.legado.app.constant.AppConst
import io.legado.app.help.config.AppConfig
import io.legado.app.help.http.CookieManager.cookieJarHeader
import io.legado.app.utils.GSON
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.ConnectionSpec
import okhttp3.Credentials
import okhttp3.FormBody
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.ResponseBody
import okio.buffer
import okio.source
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.nio.charset.Charset
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import java.util.zip.ZipInputStream
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

private val proxyClientCache = ConcurrentHashMap<String, OkHttpClient>()

private val specs = arrayOf(
    ConnectionSpec.MODERN_TLS,
    ConnectionSpec.COMPATIBLE_TLS,
    ConnectionSpec.CLEARTEXT
)

/**
 * 全局 OkHttp 客户端：与 App 的 HttpHelper 行为对齐
 * （默认 UA、Cookie 拦截、zip 解压、宽松 TLS、重定向跟随）。
 */
val okHttpClient: OkHttpClient by lazy {
    val builder = OkHttpClient.Builder()
        .connectTimeout(AppConfig.timeoutSeconds, TimeUnit.SECONDS)
        .readTimeout(AppConfig.timeoutSeconds, TimeUnit.SECONDS)
        .callTimeout(AppConfig.timeoutSeconds * 2, TimeUnit.SECONDS)
        .sslSocketFactory(SSLHelper.unsafeSSLSocketFactory, SSLHelper.unsafeTrustManager)
        .retryOnConnectionFailure(true)
        .hostnameVerifier(SSLHelper.unsafeHostnameVerifier)
        .connectionSpecs(specs.toList())
        .followRedirects(true)
        .followSslRedirects(true)
        .addInterceptor { chain ->
            val request = chain.request()
            val builder2 = request.newBuilder()
            if (request.header(AppConst.UA_NAME) == null) {
                builder2.addHeader(AppConst.UA_NAME, AppConfig.userAgent)
            } else if (request.header(AppConst.UA_NAME) == "null") {
                builder2.removeHeader(AppConst.UA_NAME)
            }
            builder2.addHeader("Accept-Language", "zh-CN,zh;q=0.9")
            chain.proceed(builder2.build())
        }
        .addNetworkInterceptor { chain ->
            var request = chain.request()
            val enableCookieJar = request.header(cookieJarHeader) != null
            if (enableCookieJar) {
                val requestBuilder = request.newBuilder()
                requestBuilder.removeHeader(cookieJarHeader)
                request = CookieManager.loadRequest(requestBuilder.build())
            }
            val networkResponse = chain.proceed(request)
            if (enableCookieJar) {
                CookieManager.saveResponse(networkResponse)
            }
            networkResponse
        }
        .addNetworkInterceptor { chain ->
            val response = chain.proceed(chain.request())
            val contentType = response.header("Content-Type") ?: ""
            if (contentType.contains("zip", true)) {
                val source = ZipInputStream(response.body.byteStream()).apply {
                    kotlin.runCatching { nextEntry }
                }.source().buffer()
                response.newBuilder()
                    .body(okhttp3.internal.http.RealResponseBody(null, -1, source))
                    .build()
            } else {
                response
            }
        }
    AppConfig.proxy?.let { proxy ->
        if (proxy.isNotBlank()) {
            runCatching {
                val r = Regex("(http|socks4|socks5)://(.*):(\\d{2,5})")
                val group = r.find(proxy) ?: return@runCatching
                val type =
                    if (group.groupValues[1] == "http") Proxy.Type.HTTP else Proxy.Type.SOCKS
                builder.proxy(Proxy(type, InetSocketAddress(group.groupValues[2], group.groupValues[3].toInt())))
            }
        }
    }
    builder.build()
}

fun getProxyClient(proxy: String? = null): OkHttpClient {
    if (proxy.isNullOrBlank()) return okHttpClient
    proxyClientCache[proxy]?.let { return it }
    val r = Regex("(http|socks4|socks5)://(.*):(\\d{2,5})(@.*@.*)?")
    val group = r.find(proxy) ?: return okHttpClient
    var username = ""
    var password = ""
    val type = if (group.groupValues[1] == "http") "http" else "socks"
    val host = group.groupValues[2]
    val port = group.groupValues[3].toInt()
    if (group.groupValues[4] != "") {
        username = group.groupValues[4].split("@")[1]
        password = group.groupValues[4].split("@")[2]
    }
    if (host.isEmpty()) return okHttpClient
    val builder = okHttpClient.newBuilder()
    builder.proxy(
        Proxy(
            if (type == "http") Proxy.Type.HTTP else Proxy.Type.SOCKS,
            InetSocketAddress(host, port)
        )
    )
    if (username != "" && password != "") {
        builder.proxyAuthenticator { _, response ->
            response.request.newBuilder()
                .header("Proxy-Authorization", Credentials.basic(username, password))
                .build()
        }
    }
    return builder.build().also { proxyClientCache[proxy] = it }
}

suspend fun OkHttpClient.newCallResponse(
    retry: Int = 0,
    builder: Request.Builder.() -> Unit
): Response {
    val requestBuilder = Request.Builder()
    requestBuilder.apply(builder)
    var response: Response? = null
    for (i in 0..retry) {
        response = newCall(requestBuilder.build()).await()
        if (response.isSuccessful) return response
    }
    return response!!
}

suspend fun OkHttpClient.newCallStrResponse(
    retry: Int = 0,
    builder: Request.Builder.() -> Unit
): StrResponse {
    return newCallResponse(retry, builder).let {
        StrResponse(it, it.body.text())
    }
}

suspend fun Call.await(): Response = suspendCancellableCoroutine { block ->
    block.invokeOnCancellation { cancel() }
    enqueue(object : Callback {
        override fun onFailure(call: Call, e: IOException) {
            block.resumeWithException(e)
        }

        override fun onResponse(call: Call, response: Response) {
            block.resume(response)
        }
    })
}

/**
 * 响应体转文本：去掉 UTF-8 BOM，优先用响应头 charset，其次按内容猜测
 */
fun ResponseBody.text(encode: String? = null): String {
    val bytes = bytes()
    val data = if (bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() &&
        bytes[2] == 0xBF.toByte()
    ) bytes.copyOfRange(3, bytes.size) else bytes
    encode?.let { return String(data, Charset.forName(it)) }
    contentType()?.charset()?.let { return String(data, it) }
    val charsetName = io.legado.app.utils.EncodingDetect.getHtmlEncode(data)
    return String(data, Charset.forName(charsetName))
}

fun Request.Builder.addHeaders(headers: Map<String, String>) {
    headers.forEach { addHeader(it.key, it.value) }
}

fun Request.Builder.get(url: String, queryMap: Map<String, String>, encoded: Boolean = false) {
    val httpBuilder = url.toHttpUrl().newBuilder()
    queryMap.forEach {
        if (encoded) httpBuilder.addEncodedQueryParameter(it.key, it.value)
        else httpBuilder.addQueryParameter(it.key, it.value)
    }
    url(httpBuilder.build())
}

fun Request.Builder.get(url: String, encodedQuery: String?) {
    val httpBuilder = url.toHttpUrl().newBuilder()
    httpBuilder.encodedQuery(encodedQuery)
    url(httpBuilder.build())
}

private val formContentType = "application/x-www-form-urlencoded".toMediaType()

fun Request.Builder.postForm(encodedForm: String) {
    post(encodedForm.toRequestBody(formContentType))
}

fun Request.Builder.postForm(form: Map<String, String>, encoded: Boolean = false) {
    val formBody = FormBody.Builder()
    form.forEach {
        if (encoded) formBody.addEncoded(it.key, it.value) else formBody.add(it.key, it.value)
    }
    post(formBody.build())
}

fun Request.Builder.postJson(json: String?) {
    json?.let {
        post(it.toRequestBody("application/json; charset=UTF-8".toMediaType()))
    }
}

fun Request.Builder.postMultipart(type: String?, form: Map<String, Any>) {
    val multipartBody = MultipartBody.Builder()
    type?.let { multipartBody.setType(it.toMediaType()) }
    form.forEach {
        when (val value = it.value) {
            is Map<*, *> -> {
                val fileName = value["fileName"] as String
                val file = value["file"]
                val mediaType = (value["contentType"] as? String)?.toMediaType()
                val requestBody = when (file) {
                    is File -> file.asRequestBody(mediaType)
                    is ByteArray -> file.toRequestBody(mediaType)
                    is String -> file.toRequestBody(mediaType)
                    else -> GSON.toJson(file).toRequestBody(mediaType)
                }
                multipartBody.addFormDataPart(it.key, fileName, requestBody)
            }

            else -> multipartBody.addFormDataPart(it.key, it.value.toString())
        }
    }
    post(multipartBody.build())
}
