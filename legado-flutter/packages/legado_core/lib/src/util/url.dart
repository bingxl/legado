/// URL 工具：对齐原版 `io.legado.app.utils.NetworkUtils` 的语义。
///
/// 为什么不直接用 `Uri.resolve`：
/// 书源里的 URL 规则经常含未替换的模板（`{{key}}`、`{$.xxx}`）和中文路径，
/// `Uri.resolve` 会做百分号转义并且对 `{`/`}` 直接抛异常。
/// 原版走的是 `java.net.URL(base, spec)`，只做路径拼接与 `.`/`..` 归一化，
/// 不做任何转义 —— 这里照抄该行为。
library;

/// 是否为绝对地址（只认 http/https）。
bool isAbsUrl(String? s) {
  if (s == null) return false;
  final t = s.trim().toLowerCase();
  return t.startsWith('http://') || t.startsWith('https://');
}

/// 是否为 `data:` 协议。
bool isDataUrl(String? s) {
  if (s == null) return false;
  return s.trim().toLowerCase().startsWith('data:');
}

/// 取 `协议://域名`，失败返回 null。
String? getBaseUrl(String? url) {
  if (url == null || url.isEmpty) return null;
  final lower = url.toLowerCase();
  final idx = lower.indexOf('://');
  if (idx < 0) return null;
  if (!lower.startsWith('http://') && !lower.startsWith('https://')) return null;
  final rest = url.substring(idx + 3);
  final slash = rest.indexOf('/');
  if (slash < 0) return url;
  return url.substring(0, idx + 3 + slash);
}

/// 相对地址转绝对地址。
///
/// - 空串返回空串（调用方决定是否回落到 baseUrl）
/// - 已是绝对地址 / data: 原样返回
/// - `javascript:` 返回空串（原版如此，避免把脚本当链接）
String getAbsoluteUrl(String? baseUrl, String? relativePath) {
  final rel = (relativePath ?? '').trim();
  final base = (baseUrl ?? '').trim();
  if (base.isEmpty) return rel;
  if (isAbsUrl(rel)) return rel;
  if (isDataUrl(rel)) return rel;
  if (rel.toLowerCase().startsWith('javascript')) return '';
  // 书源 url 常带 `,{...}` 选项，只取前段
  var b = base;
  final comma = b.indexOf(',');
  if (comma >= 0) b = b.substring(0, comma);
  return joinUrl(b, rel);
}

/// 按 `java.net.URL(base, spec)` 的语义拼接地址（不做百分号转义）。
String joinUrl(String base, String rel) {
  final uri = Uri.tryParse(base);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) return rel;
  // 用 authority 而不是 host：本地测试服务器、自建站点常在 http 后面带端口，
  // 用 host 会把 `:8080` 悄悄丢掉，结果请求打到 80 端口。
  final prefix = '${uri.scheme}://${uri.authority}';
  final path = uri.path;
  final query = uri.hasQuery ? '?${uri.query}' : '';
  if (rel.isEmpty) return '$prefix$path$query';
  if (rel.startsWith('//')) return '${uri.scheme}:$rel';
  if (rel.startsWith('/')) return prefix + normalizeUrlPath(rel);
  if (rel.startsWith('?')) return '$prefix$path$rel';
  if (rel.startsWith('#')) return '$prefix$path$query$rel';
  if (_hasScheme(rel)) return rel;
  var dir = path;
  final lastSlash = dir.lastIndexOf('/');
  dir = lastSlash >= 0 ? dir.substring(0, lastSlash + 1) : '/';
  return prefix + normalizeUrlPath('$dir$rel');
}

/// 归一化 `.` / `..`（query/fragment 原样保留）。
String normalizeUrlPath(String p) {
  var path = p;
  var rest = '';
  final cut = path.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) {
    rest = path.substring(cut);
    path = path.substring(0, cut);
  }
  if (path.isEmpty) return rest;
  var trailing = path.endsWith('/');
  final segs = path.split('/');
  final out = <String>[];
  for (var i = 0; i < segs.length; i++) {
    final s = segs[i];
    if (s == '.') {
      if (i == segs.length - 1) trailing = true;
      continue;
    }
    if (s == '..') {
      if (out.length > 1) out.removeLast();
      if (i == segs.length - 1) trailing = true;
      continue;
    }
    // 保留首段空串（绝对路径的根）
    if (s.isEmpty && i != 0) continue;
    out.add(s);
  }
  var result = out.join('/');
  if (!result.startsWith('/')) result = '/$result';
  if (trailing && !result.endsWith('/')) result = '$result/';
  return result + rest;
}

bool _hasScheme(String s) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isAlpha = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
    if (isAlpha) continue;
    final isDigit = c >= 0x30 && c <= 0x39;
    if (isDigit || c == 0x2B || c == 0x2D || c == 0x2E) {
      if (i == 0) return false;
      continue;
    }
    if (c == 0x3A) return i > 0;
    return false;
  }
  return false;
}
