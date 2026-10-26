package io.legado.app.utils

import cn.hutool.crypto.digest.DigestUtil
import cn.hutool.crypto.digest.Digester
import java.io.InputStream
import kotlin.concurrent.getOrSet

@Suppress("unused")
object MD5Utils {

    private val threadLocal = ThreadLocal<Digester>()

    private val MD5Digester
        get() = threadLocal.getOrSet { DigestUtil.digester("MD5") }

    fun md5Encode(str: String?): String = MD5Digester.digestHex(str)

    fun md5Encode(inputStream: InputStream): String = MD5Digester.digestHex(inputStream)

    fun md5Encode16(str: String): String = md5Encode(str).substring(8, 24)
}
