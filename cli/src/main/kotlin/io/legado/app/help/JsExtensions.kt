package io.legado.app.help

import androidx.annotation.Keep
import cn.hutool.core.codec.Base64
import cn.hutool.core.util.HexUtil
import com.script.rhino.rhinoContext
import com.script.rhino.rhinoContextOrNull
import io.legado.app.constant.AppConst
import io.legado.app.constant.AppConst.dateFormat
import io.legado.app.constant.AppLog
import io.legado.app.constant.AppPattern
import io.legado.app.data.entities.BaseSource
import io.legado.app.exception.NoStackTraceException
import io.legado.app.help.config.AppConfig
import io.legado.app.help.config.CliStorage
import io.legado.app.help.http.CookieManager.cookieJarHeader
import io.legado.app.help.http.CookieStore
import io.legado.app.help.http.SSLHelper
import io.legado.app.help.http.StrResponse
import io.legado.app.help.http.newCallResponse
import io.legado.app.help.http.okHttpClient
import io.legado.app.model.Debug
import io.legado.app.model.analyzeRule.AnalyzeUrl
import io.legado.app.model.analyzeRule.QueryTTF
import io.legado.app.utils.EncoderUtils
import io.legado.app.utils.GSON
import io.legado.app.utils.HtmlFormatter
import io.legado.app.utils.NetworkUtils
import io.legado.app.utils.MD5Utils
import io.legado.app.utils.StringUtils
import io.legado.app.utils.EncodingDetect
import io.legado.app.utils.fromJsonObject
import io.legado.app.utils.isAbsUrl
import io.legado.app.utils.mapAsync
import io.legado.app.utils.stackTraceStr
import io.legado.app.utils.toStringArray
import kotlinx.coroutines.Dispatchers.IO
import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.jsoup.Connection
import org.jsoup.Jsoup
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.URLEncoder
import java.nio.charset.Charset
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.SimpleTimeZone
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext

/**
 * js 扩展类，在 js 中通过 java 变量调用。
 *
 * 与 App 的 JsExtensions 保持同名同签名；差别只有两类：
 * 1. 依赖 Android WebView / 内置浏览器的 6 个方法（webView、startBrowser、验证码等）直接报错
 * 2. App 私有缓存目录换成本地目录（CliStorage）
 */
@Keep
@Suppress("unused")
interface JsExtensions : JsEncodeUtils {

    fun getSource(): BaseSource?

    val context: CoroutineContext
        get() = rhinoContext.coroutineContext ?: EmptyCoroutineContext

    /**
     * 访问网络,返回String
     */
    fun ajax(url: Any): String? {
        val urlStr = if (url is List<*>) {
            url.firstOrNull().toString()
        } else {
            url.toString()
        }
        val analyzeUrl = AnalyzeUrl(urlStr, source = getSource(), coroutineContext = context)
        return kotlin.runCatching {
            analyzeUrl.getStrResponse().body
        }.onFailure {
            rhinoContext.ensureActive()
            AppLog.put("ajax(${urlStr}) error\n${it.localizedMessage}", it)
        }.getOrElse {
            it.stackTraceStr
        }
    }

    /**
     * 并发访问网络
     */
    fun ajaxAll(urlList: Array<String>): Array<StrResponse> {
        return runBlocking(context) {
            urlList.asFlow().mapAsync(AppConfig.threadCount) { url ->
                val analyzeUrl = AnalyzeUrl(
                    url,
                    source = getSource(),
                    coroutineContext = coroutineContext
                )
                analyzeUrl.getStrResponseAwait()
            }.flowOn(IO).toList().toTypedArray()
        }
    }

    fun connect(urlStr: String): StrResponse {
        val analyzeUrl = AnalyzeUrl(urlStr, source = getSource(), coroutineContext = context)
        return kotlin.runCatching {
            analyzeUrl.getStrResponse()
        }.onFailure {
            rhinoContext.ensureActive()
            AppLog.put("connect(${urlStr}) error\n${it.localizedMessage}", it)
        }.getOrElse {
            StrResponse(analyzeUrl.url, it.stackTraceStr)
        }
    }

    fun connect(urlStr: String, header: String?): StrResponse {
        val headerMap = GSON.fromJsonObject<Map<String, String>>(header).getOrNull()
        val analyzeUrl = AnalyzeUrl(
            urlStr,
            headerMapF = headerMap,
            source = getSource(),
            coroutineContext = context
        )
        return kotlin.runCatching {
            analyzeUrl.getStrResponse()
        }.onFailure {
            rhinoContext.ensureActive()
            AppLog.put("ajax($urlStr,$header) error\n${it.localizedMessage}", it)
        }.getOrElse {
            StrResponse(analyzeUrl.url, it.stackTraceStr)
        }
    }

    fun webView(html: String?, url: String?, js: String?): String? {
        throw NoStackTraceException("桌面 CLI 不支持 WebView，请改用 @js: 或 ajax")
    }

    fun webViewGetSource(html: String?, url: String?, js: String?, sourceRegex: String): String? {
        throw NoStackTraceException("桌面 CLI 不支持 WebView，请改用 @js: 或 ajax")
    }

    fun webViewGetOverrideUrl(
        html: String?,
        url: String?,
        js: String?,
        overrideUrlRegex: String
    ): String? {
        throw NoStackTraceException("桌面 CLI 不支持 WebView，请改用 @js: 或 ajax")
    }

    fun startBrowser(url: String, title: String) {
        throw NoStackTraceException("桌面 CLI 不支持内置浏览器（$url）")
    }

    fun startBrowserAwait(url: String, title: String, refetchAfterSuccess: Boolean): StrResponse {
        throw NoStackTraceException("桌面 CLI 不支持内置浏览器（$url）")
    }

    fun startBrowserAwait(url: String, title: String): StrResponse {
        return startBrowserAwait(url, title, true)
    }

    fun getVerificationCode(imageUrl: String): String {
        throw NoStackTraceException("桌面 CLI 不支持验证码识别（$imageUrl）")
    }

    /**
     * 缓存以文本方式保存的文件 如 .js .txt
     */
    fun importScript(path: String): String {
        val result = when {
            path.startsWith("http") -> cacheFile(path)
            else -> readTxtFile(path)
        }
        if (result.isBlank()) throw NoStackTraceException("$path 内容获取失败或者为空")
        return result
    }

    fun cacheFile(urlStr: String): String = cacheFile(urlStr, 0)

    fun cacheFile(urlStr: String, saveTime: Int): String {
        val key = md5Encode16(urlStr)
        val cachePath = CacheManager.get(key)
        return if (cachePath.isNullOrBlank() || !getFile(cachePath).exists()) {
            val path = downloadFile(urlStr)
            log("首次下载 $urlStr >> $path")
            CacheManager.put(key, path, saveTime)
            readTxtFile(path)
        } else {
            readTxtFile(cachePath)
        }
    }

    fun getCookie(tag: String): String = getCookie(tag, null)

    fun getCookie(tag: String, key: String?): String {
        return if (key != null) CookieStore.getKey(tag, key) else CookieStore.getCookie(tag)
    }

    fun downloadFile(url: String): String {
        rhinoContext.ensureActive()
        val analyzeUrl = AnalyzeUrl(url, source = getSource(), coroutineContext = context)
        val type = analyzeUrl.type ?: url.substringAfterLast('.', "")
        val path = File(cacheFolder(), "${MD5Utils.md5Encode16(url)}.$type").absolutePath
        val file = File(path)
        file.delete()
        file.parentFile?.mkdirs()
        analyzeUrl.getInputStream().use { iStream ->
            file.outputStream().buffered().use { oStream ->
                iStream.copyTo(oStream)
            }
        }
        return path.substring(cacheFolder().length)
    }

    fun downloadFile(content: String, url: String): String {
        rhinoContext.ensureActive()
        val type = AnalyzeUrl(url, source = getSource(), coroutineContext = context).type
            ?: return ""
        val path = File(cacheFolder(), "${MD5Utils.md5Encode16(url)}.$type").absolutePath
        val file = File(path)
        file.parentFile?.mkdirs()
        HexUtil.decodeHex(content).let {
            if (it.isNotEmpty()) file.writeBytes(it)
        }
        return path.substring(cacheFolder().length)
    }

    fun get(urlStr: String, headers: Map<String, String>): Connection.Response {
        val requestHeaders = if (getSource()?.enabledCookieJar == true) {
            headers.toMutableMap().apply { put(cookieJarHeader, "1") }
        } else headers
        return Jsoup.connect(urlStr)
            .sslSocketFactory(SSLHelper.unsafeSSLSocketFactory)
            .ignoreContentType(true)
            .followRedirects(false)
            .headers(requestHeaders)
            .method(Connection.Method.GET)
            .execute()
    }

    fun head(urlStr: String, headers: Map<String, String>): Connection.Response {
        val requestHeaders = if (getSource()?.enabledCookieJar == true) {
            headers.toMutableMap().apply { put(cookieJarHeader, "1") }
        } else headers
        return Jsoup.connect(urlStr)
            .sslSocketFactory(SSLHelper.unsafeSSLSocketFactory)
            .ignoreContentType(true)
            .followRedirects(false)
            .headers(requestHeaders)
            .method(Connection.Method.HEAD)
            .execute()
    }

    fun post(urlStr: String, body: String, headers: Map<String, String>): Connection.Response {
        val requestHeaders = if (getSource()?.enabledCookieJar == true) {
            headers.toMutableMap().apply { put(cookieJarHeader, "1") }
        } else headers
        return Jsoup.connect(urlStr)
            .sslSocketFactory(SSLHelper.unsafeSSLSocketFactory)
            .ignoreContentType(true)
            .followRedirects(false)
            .requestBody(body)
            .headers(requestHeaders)
            .method(Connection.Method.POST)
            .execute()
    }

    fun strToBytes(str: String): ByteArray = str.toByteArray(Charset.forName("UTF-8"))

    fun strToBytes(str: String, charset: String): ByteArray = str.toByteArray(Charset.forName(charset))

    fun bytesToStr(bytes: ByteArray): String = String(bytes, Charset.forName("UTF-8"))

    fun bytesToStr(bytes: ByteArray, charset: String): String = String(bytes, Charset.forName(charset))

    fun base64Decode(str: String?): String = Base64.decodeStr(str)

    fun base64Decode(str: String?, charset: String): String =
        Base64.decodeStr(str, Charset.forName(charset))

    fun base64Decode(str: String, flags: Int): String = EncoderUtils.base64Decode(str, flags)

    fun base64DecodeToByteArray(str: String?): ByteArray? {
        if (str.isNullOrBlank()) return null
        return EncoderUtils.base64DecodeToByteArray(str, 0)
    }

    fun base64DecodeToByteArray(str: String?, flags: Int): ByteArray? {
        if (str.isNullOrBlank()) return null
        return EncoderUtils.base64DecodeToByteArray(str, flags)
    }

    fun base64Encode(str: String): String? = EncoderUtils.base64Encode(str, 2)

    fun base64Encode(str: String, flags: Int): String? = EncoderUtils.base64Encode(str, flags)

    fun hexDecodeToByteArray(hex: String): ByteArray? = HexUtil.decodeHex(hex)

    fun hexDecodeToString(hex: String): String? = HexUtil.decodeHexStr(hex)

    fun hexEncodeToString(utf8: String): String? = HexUtil.encodeHexStr(utf8)

    fun timeFormatUTC(time: Long, format: String, sh: Int): String? {
        val utc = SimpleTimeZone(sh, "UTC")
        return SimpleDateFormat(format, Locale.getDefault()).run {
            timeZone = utc
            format(Date(time))
        }
    }

    fun timeFormat(time: Long): String = dateFormat.format(Date(time))

    fun encodeURI(str: String): String {
        return try {
            URLEncoder.encode(str, "UTF-8")
        } catch (e: Exception) {
            ""
        }
    }

    fun encodeURI(str: String, enc: String): String {
        return try {
            URLEncoder.encode(str, enc)
        } catch (e: Exception) {
            ""
        }
    }

    fun htmlFormat(str: String): String = HtmlFormatter.formatKeepImg(str)

    /**
     * 简繁转换：桌面端没有接入转换表，原样返回（不影响解析流程）
     */
    fun t2s(text: String): String = text

    fun s2t(text: String): String = text

    fun getWebViewUA(): String = AppConfig.userAgent

    //**************** 文件操作（相对 CliStorage.cacheDir/js） ****************//

    fun getFile(path: String): File {
        val cachePath = cacheFolder()
        val aPath = if (path.startsWith(File.separator)) cachePath + path else cachePath + File.separator + path
        val file = File(aPath)
        if (!file.canonicalPath.startsWith(cachePath)) {
            throw SecurityException("非法路径")
        }
        return file
    }

    fun readFile(path: String): ByteArray? {
        val file = getFile(path)
        return if (file.exists()) file.readBytes() else null
    }

    fun readTxtFile(path: String): String {
        val file = getFile(path)
        if (!file.exists()) return ""
        val charsetName = EncodingDetect.getEncode(file)
        return String(file.readBytes(), Charset.forName(charsetName))
    }

    fun readTxtFile(path: String, charsetName: String): String {
        val file = getFile(path)
        if (!file.exists()) return ""
        return String(file.readBytes(), Charset.forName(charsetName))
    }

    fun deleteFile(path: String): Boolean {
        val file = getFile(path)
        return file.deleteRecursively()
    }

    fun unzipFile(zipPath: String): String = unArchiveFile(zipPath)

    fun un7zFile(zipPath: String): String = unArchiveFile(zipPath)

    fun unrarFile(zipPath: String): String = unArchiveFile(zipPath)

    /**
     * 仅支持 zip（桌面端未内置 rar/7z 解码器）
     */
    fun unArchiveFile(zipPath: String): String {
        if (zipPath.isEmpty()) return ""
        val zipFile = getFile(zipPath)
        val target = File(cacheFolder(), "unzip_" + MD5Utils.md5Encode16(zipFile.name))
        target.mkdirs()
        ZipInputStream(zipFile.inputStream().buffered()).use { zis ->
            var entry: ZipEntry? = zis.nextEntry
            while (entry != null) {
                val outFile = File(target, entry.name)
                if (entry.isDirectory) {
                    outFile.mkdirs()
                } else {
                    outFile.parentFile?.mkdirs()
                    outFile.outputStream().use { zis.copyTo(it) }
                }
                entry = zis.nextEntry
            }
        }
        return "unzip_" + MD5Utils.md5Encode16(zipFile.name)
    }

    fun getTxtInFolder(path: String): String {
        if (path.isEmpty()) return ""
        val folder = getFile(path)
        val contents = StringBuilder()
        folder.listFiles()?.forEach { f ->
            val charsetName = EncodingDetect.getEncode(f)
            contents.append(String(f.readBytes(), Charset.forName(charsetName))).append("\n")
        }
        folder.deleteRecursively()
        return contents.toString().trimEnd('\n')
    }

    fun getZipStringContent(url: String, path: String): String {
        val byteArray = getZipByteArrayContent(url, path) ?: return ""
        val charsetName = EncodingDetect.getEncode(byteArray)
        return String(byteArray, Charset.forName(charsetName))
    }

    fun getZipStringContent(url: String, path: String, charsetName: String): String {
        val byteArray = getZipByteArrayContent(url, path) ?: return ""
        return String(byteArray, Charset.forName(charsetName))
    }

    fun getRarStringContent(url: String, path: String): String = getZipStringContent(url, path)

    fun getRarStringContent(url: String, path: String, charsetName: String): String =
        getZipStringContent(url, path, charsetName)

    fun get7zStringContent(url: String, path: String): String = getZipStringContent(url, path)

    fun get7zStringContent(url: String, path: String, charsetName: String): String =
        getZipStringContent(url, path, charsetName)

    fun getZipByteArrayContent(url: String, path: String): ByteArray? {
        val bytes = if (url.isAbsUrl()) {
            AnalyzeUrl(url, source = getSource(), coroutineContext = context).getByteArray()
        } else {
            HexUtil.decodeHex(url)
        }
        val bos = ByteArrayOutputStream()
        ZipInputStream(ByteArrayInputStream(bytes)).use { zis ->
            var entry: ZipEntry? = zis.nextEntry
            while (entry != null) {
                if (entry.name == path) {
                    zis.copyTo(bos)
                    return bos.toByteArray()
                }
                entry = zis.nextEntry
            }
        }
        log("getZipContent 未发现内容")
        return null
    }

    fun getRarByteArrayContent(url: String, path: String): ByteArray? = getZipByteArrayContent(url, path)

    fun get7zByteArrayContent(url: String, path: String): ByteArray? = getZipByteArrayContent(url, path)

    //**************** 字体解析 ****************//

    @Deprecated("Deprecated", ReplaceWith("queryTTF(data)"))
    fun queryBase64TTF(data: String?): QueryTTF? = queryTTF(data)

    fun queryTTF(data: Any?, useCache: Boolean): QueryTTF? {
        return try {
            when (data) {
                is String -> {
                    val font: ByteArray? = if (data.isAbsUrl()) {
                        AnalyzeUrl(data, source = getSource(), coroutineContext = context)
                            .getByteArray()
                    } else {
                        base64DecodeToByteArray(data)
                    }
                    font?.let { QueryTTF(it) }
                }

                is ByteArray -> QueryTTF(data)
                else -> null
            }
        } catch (e: Exception) {
            AppLog.put("[queryTTF] 获取字体处理类出错", e)
            throw e
        }
    }

    fun queryTTF(data: Any?): QueryTTF? = queryTTF(data, true)

    fun replaceFont(
        text: String,
        errorQueryTTF: QueryTTF?,
        correctQueryTTF: QueryTTF?,
        filter: Boolean
    ): String {
        if (errorQueryTTF == null || correctQueryTTF == null) return text
        val contentArray = text.toStringArray()
        val intArray = IntArray(1)
        contentArray.forEachIndexed { index, s ->
            val oldCode = s.codePointAt(0)
            if (errorQueryTTF.isBlankUnicode(oldCode)) return@forEachIndexed
            var glyf = errorQueryTTF.getGlyfByUnicode(oldCode)
            if (errorQueryTTF.getGlyfIdByUnicode(oldCode) == 0) glyf = null
            if (filter && glyf == null) {
                contentArray[index] = ""
                return@forEachIndexed
            }
            val code = correctQueryTTF.getUnicodeByGlyf(glyf)
            if (code != 0) {
                intArray[0] = code
                contentArray[index] = String(intArray, 0, 1)
            }
        }
        return contentArray.joinToString("")
    }

    fun replaceFont(text: String, errorQueryTTF: QueryTTF?, correctQueryTTF: QueryTTF?): String {
        return replaceFont(text, errorQueryTTF, correctQueryTTF, false)
    }

    fun toNumChapter(s: String?): String? {
        s ?: return null
        val matcher = AppPattern.titleNumPattern.matcher(s)
        if (matcher.find()) {
            val intStr = StringUtils.stringToInt(matcher.group(2))
            return "${matcher.group(1)}$intStr${matcher.group(3)}"
        }
        return s
    }

    fun toast(msg: Any?) {
        System.err.println("${getSource()?.getTag()}: $msg")
    }

    fun longToast(msg: Any?) = toast(msg)

    fun log(msg: Any?): Any? {
        rhinoContextOrNull?.ensureActive()
        getSource()?.let { Debug.log(it.getKey(), msg.toString()) }
            ?: Debug.log(msg.toString())
        return msg
    }

    fun logType(any: Any?) {
        log(any?.javaClass?.name ?: "null")
    }

    fun randomUUID(): String = UUID.randomUUID().toString()

    fun androidId(): String = AppConst.androidId

    fun openUrl(url: String) {
        throw NoStackTraceException("桌面 CLI 不支持打开外部页面（$url）")
    }

    fun openUrl(url: String, mimeType: String?) {
        openUrl(url)
    }

    fun getAbsoluteURL(baseUrl: String?, relativePath: String): String {
        return NetworkUtils.getAbsoluteURL(baseUrl, relativePath)
    }

    fun sha256(str: String): String {
        return MessageDigest.getInstance("SHA-256").digest(str.toByteArray()).joinToString("") {
            "%02x".format(it)
        }
    }

    private fun cacheFolder(): String = File(CliStorage.cacheDir, "js").apply { mkdirs() }.absolutePath

    @Suppress("unused")
    private suspend fun newCallHelper(url: String) = okHttpClient.newCallResponse { url(url) }
}
