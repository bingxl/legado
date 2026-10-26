package io.legado.app.help

import cn.hutool.crypto.digest.DigestUtil
import cn.hutool.crypto.symmetric.SymmetricCrypto
import io.legado.app.utils.MD5Utils

/**
 * js 加解密扩展：与 App 的 JsEncodeUtils 同名同签名，
 * 底层同样使用 hutool（桌面 JVM 可直接用）。
 */
@Suppress("unused")
interface JsEncodeUtils {

    fun md5Encode(str: String): String = MD5Utils.md5Encode(str)

    fun md5Encode16(str: String): String = MD5Utils.md5Encode16(str)

    fun createSymmetricCrypto(
        transformation: String,
        key: ByteArray?,
        iv: ByteArray?
    ): SymmetricCrypto {
        val symmetricCrypto = if (key == null) {
            SymmetricCrypto(transformation)
        } else {
            SymmetricCrypto(transformation, key)
        }
        return if (iv != null && iv.isNotEmpty()) symmetricCrypto.setIv(iv) else symmetricCrypto
    }

    fun createSymmetricCrypto(transformation: String, key: ByteArray): SymmetricCrypto {
        return createSymmetricCrypto(transformation, key, null)
    }

    fun createSymmetricCrypto(transformation: String, key: String): SymmetricCrypto {
        return createSymmetricCrypto(transformation, key.encodeToByteArray(), null)
    }

    fun createSymmetricCrypto(
        transformation: String,
        key: String,
        iv: String?
    ): SymmetricCrypto {
        return createSymmetricCrypto(
            transformation, key.encodeToByteArray(), iv?.encodeToByteArray()
        )
    }

    fun sha1Encode(str: String): String = DigestUtil.sha1Hex(str)

    fun sha256Encode(str: String): String = DigestUtil.sha256Hex(str)

    fun hmacEncode(algorithm: String, key: String, data: String): String {
        return cn.hutool.crypto.digest.HMac(algorithm, key.encodeToByteArray())
            .digestHex(data)
    }
}
