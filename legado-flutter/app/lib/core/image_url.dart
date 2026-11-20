/// 图片地址归一化。
///
/// 书源里的图片地址有三种常见形态，直接交给 `Image.network` 都会失败：
///
/// - `//cdn.example.com/a.jpg`：协议相对地址，必须补 `https:`；
/// - `https://a/b.jpg?x=1&amp;y=2`：XML/HTML 转义没解开，`&amp;` 要还原成 `&`；
/// - 相对路径（`/img/a.jpg`、`a.jpg`）：没有基准地址可拼，只能交给兜底图。
///
/// 归一化只做「能明确判断」的修正，不猜站点域名——core 返回的图片直链
/// 已经按章节地址拼过绝对路径，这里再补一层是防书源作者直接写协议相对地址。
library;

/// 把书源/接口给的图片地址转成可直接请求的绝对 URL。
///
/// 无法确定（空串、相对路径、非 http(s) 协议）时返回 null，
/// 调用方据此显示占位图，而不是让 `Image.network` 抛异常。
/// 请求图片时附带的头。
///
/// 大量小说站的图片 CDN 有防盗链：不带 Referer 直接 403（超星
/// `p.ananas.chaoxing.com` 就是如此，书源里给的直链本身完全正确）。
/// 这里统一用「图片地址自身的 origin」作 Referer，既能过绝大多数
/// CDN 的「同源/白名单」校验，又不会把书站 Cookie 泄漏给第三方域名。
Map<String, String> imageHeaders(String url) {
  final uri = Uri.tryParse(url);
  final origin = uri != null && uri.host.isNotEmpty
      ? '${uri.scheme}://${uri.host}/'
      : '';
  return <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    if (origin.isNotEmpty) 'Referer': origin,
  };
}

String? normalizeImageUrl(String? raw) {
  if (raw == null) return null;
  var url = raw.trim();
  if (url.isEmpty) return null;

  // HTML 实体：JSON 里偶尔会把 & 写成 &amp;（DOM 规则更容易遇到）。
  url = url
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>');

  // 协议相对：//host/path —— 站点是 http 时浏览器也会用 http，
  // 但图片 CDN 基本都支持 https，优先用它避免明文流量。
  if (url.startsWith('//')) url = 'https:$url';

  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (!uri.hasScheme) return null;
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  if (uri.host.isEmpty) return null;
  return url;
}
