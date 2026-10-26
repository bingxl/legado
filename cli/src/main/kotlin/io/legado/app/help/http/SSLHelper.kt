package io.legado.app.help.http

import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/**
 * 书源站点的证书经常不规范（自签、过期），App 里同样选择信任全部证书，
 * 否则大量源会直接失败。
 */
object SSLHelper {

    val unsafeTrustManager: X509TrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit

        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    val unsafeSSLSocketFactory: SSLSocketFactory by lazy {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(unsafeTrustManager), SecureRandom())
        context.socketFactory
    }

    val unsafeHostnameVerifier = javax.net.ssl.HostnameVerifier { _, _ -> true }
}
