package flutter.legado.bingxl.cn

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.webkit.CookieManager
import android.webkit.WebSettings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/// Flutter 宿主。内核是纯 Dart，这里只放「内核做不了」的平台能力：
/// PDF 逐页渲染走 Android 自带的 PdfRenderer（与原版 Kotlin PdfFile 一致），
/// 不引入 Pdfium/PDFView 之类第三方依赖，离线也没有网络请求。
class MainActivity : FlutterActivity() {
  companion object {
    private const val CHANNEL = "flutter.legado/pdf"
    private const val WEBVIEW_CHANNEL = "flutter.legado/webview"
  }

  /// 渲染在单线程上串行：PdfRenderer 不是线程安全的，
  /// 而且 MethodChannel 回调默认在主线程，直接渲染会掉帧。
  private val executor = Executors.newSingleThreadExecutor { runnable ->
    Thread(runnable, "legado-pdf-render").apply { isDaemon = true }
  }

  /// 按路径缓存打开中的文档。切章/来回翻页不必反复 open，
  /// 关闭阅读页时再统一释放（见 close / onDestroy）。
  private val holders = mutableMapOf<String, RendererHolder>()

  private class RendererHolder(
    val fd: ParcelFileDescriptor,
    val renderer: PdfRenderer,
  )

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    configureWebViewChannel(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "pageCount" -> executor.execute {
            try {
              result.success(open(call.path()).renderer.pageCount)
            } catch (e: Exception) {
              result.error("PDF_ERROR", e.message, null)
            }
          }

          "renderPage" -> executor.execute {
            try {
              val holder = open(call.path())
              val renderer = holder.renderer
              val pageIndex = call.argument<Int>("page") ?: 0
              if (pageIndex < 0 || pageIndex >= renderer.pageCount) {
                result.error("PAGE_OUT_OF_RANGE", "页码越界: $pageIndex", null)
                return@execute
              }
              val width = (call.argument<Int>("width") ?: 1080).coerceIn(1, 2560)
              val page = renderer.openPage(pageIndex)
              try {
                val scale = width.toFloat() / page.width.toFloat()
                val height = (page.height * scale).toInt().coerceIn(1, 4096)
                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                val bytes = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, bytes)
                bitmap.recycle()
                result.success(bytes.toByteArray())
              } finally {
                page.close()
              }
            } catch (e: Exception) {
              result.error("PDF_ERROR", e.message, null)
            }
          }

          "close" -> executor.execute {
            close(call.path())
            result.success(null)
          }

          else -> result.notImplemented()
        }
      }
  }

  private fun MethodCall.path(): String =
    argument<String>("path")?.takeIf { it.isNotEmpty() }
      ?: throw IllegalArgumentException("缺少 PDF 文件路径")

  /// 反爬人机验证（Cloudflare 五秒盾 / 图片验证码）用的平台能力。
  ///
  /// `webview_flutter` 只提供「写 cookie」，而 `cf_clearance` 是 HttpOnly ——
  /// 页面 JS 的 `document.cookie` 读不到它，只能由原生侧从浏览器 cookie jar 里取。
  /// 这里用的就是原版 `WebViewActivity.onPageFinished` 里那套
  /// `CookieManager.getInstance().getCookie(url)`。
  private fun configureWebViewChannel(flutterEngine: FlutterEngine) {
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WEBVIEW_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          // 必须留在主线程：CookieManager 内部要求在同一线程访问。
          "cookies" -> {
            val url = call.argument<String>("url")
            if (url.isNullOrEmpty()) {
              result.error("INVALID_ARGUMENT", "缺少 url", null)
            } else {
              result.success(CookieManager.getInstance().getCookie(url))
            }
          }

          // 验证时用的 UA 与它绑定：cf_clearance 换了 UA 就失效。
          "userAgent" -> result.success(WebSettings.getDefaultUserAgent(this))

          else -> result.notImplemented()
        }
      }
  }

  @Synchronized
  private fun open(path: String): RendererHolder {
    holders[path]?.let { return it }
    val file = File(path)
    if (!file.exists()) throw IllegalArgumentException("PDF 文件不存在: $path")
    val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    val renderer = try {
      PdfRenderer(fd)
    } catch (e: Exception) {
      fd.close()
      throw e
    }
    val holder = RendererHolder(fd, renderer)
    holders[path] = holder
    return holder
  }

  @Synchronized
  private fun close(path: String) {
    holders.remove(path)?.let { holder ->
      try {
        holder.renderer.close()
      } catch (_: Exception) {
      }
      try {
        holder.fd.close()
      } catch (_: Exception) {
      }
    }
  }

  override fun onDestroy() {
    super.onDestroy()
    executor.shutdownNow()
    holders.keys.toList().forEach { close(it) }
  }
}
