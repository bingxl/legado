/// WebDAV 协议层最小实现（对齐 Kotlin `lib/webdav/WebDav.kt`）。
///
/// 只依赖 net 门面 + `xml` 解析，不碰任何存储/UI，方便单独测试。
/// 职责：把「WebDAV 配置」变成「能列目录 / 下载 / 上传 / 删除 / 建目录」的原语。
library;

import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:xml/xml.dart' as xml;

import '../../kernel/errors.dart';
import '../../net/net.dart';

final Logger _log = Logger('legado.webdav');

/// WebDAV 连接参数。密码明文只在内存里流转，落盘/视图脱敏由 service 层负责。
class WebDavConnection {
  const WebDavConnection({
    required this.url,
    this.username = '',
    this.password = '',
    this.rootPath = '',
  });

  /// 服务器根地址，如 `https://dav.jianguoyun.com/dav/`。
  final String url;

  final String username;
  final String password;

  /// 工作根（相对 [url] 的子目录），如 `legado`。列目录/导入都限定在此之下。
  final String rootPath;

  bool get configured => url.trim().isNotEmpty;
}

/// PROPFIND 解析出来的一条 WebDAV 资源。
class WebDavEntry {
  WebDavEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modTime = 0,
    this.contentType = '',
  });

  /// 相对「工作根」的路径（service 层保证），如 `sub/a.txt`。
  final String path;
  final String name;
  final bool isDir;
  final int size;

  /// Unix 毫秒。
  final int modTime;
  final String contentType;

  Map<String, Object?> toJson() => <String, Object?>{
        'path': path,
        'name': name,
        'isDir': isDir,
        'size': size,
        'modTime': modTime,
      };
}

/// WebDAV 协议客户端。
///
/// URL 规则（对齐 Kotlin `AppWebDav`）：
/// - 强制 `http://` / `https://`（`dav://` → `http://`，`davs://` → `https://`）；
/// - [url] 与 [rootPath] 之间补一个 `/`，末尾也补 `/` —— PROPFIND 对目录必须带尾斜杠，
///   否则部分服务器（坚果云）会 301，而 301 会把 PROPFIND 降级成 GET（见 net 层）。
class WebDavClient {
  WebDavClient(this.connection, {NetClient? net, Duration timeout = const Duration(minutes: 2)})
      : _net = net ?? NetClient(timeout: timeout);

  final WebDavConnection connection;
  final NetClient _net;

  String get _baseUrl => _normalizeBase(connection.url);
  String get _workRoot => _joinRoot(_baseUrl, connection.rootPath);

  /// 把用户填的地址规范成以 `/` 结尾的 http(s) URL。
  static String normalizeUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('davs://')) {
      s = 'https://${s.substring(7)}';
    } else if (s.startsWith('dav://')) {
      s = 'http://${s.substring(6)}';
    }
    return _normalizeBase(s);
  }

  static String _normalizeBase(String raw) {
    var s = raw.trim();
    if (!s.startsWith('http://') && !s.startsWith('https://')) {
      s = 'https://$s';
    }
    if (!s.endsWith('/')) s += '/';
    return s;
  }

  /// 把相对子目录拼到 base 之下，结果以 `/` 结尾。
  static String _joinRoot(String base, String sub) {
    var clean = sub.trim().replaceAll(r'\', '/');
    while (clean.startsWith('/')) {
      clean = clean.substring(1);
    }
    while (clean.endsWith('/') && clean.isNotEmpty) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (clean.isEmpty) return base;
    return '$base$clean/';
  }

  Map<String, String> get _authHeaders {
    final h = <String, String>{
      'user-agent': kDefaultUserAgent,
    };
    if (connection.username.isNotEmpty || connection.password.isNotEmpty) {
      // Kotlin 用 ISO-8859-1（Authorization.kt）；latin1 与之等价，且对非 ASCII
      // 用户名/密码会抛异常——WebDAV 基本都是 ASCII 凭据，这里保持一致。
      final cred = base64.encode(latin1.encode('${connection.username}:${connection.password}'));
      h['authorization'] = 'Basic $cred';
    }
    return h;
  }

  /// 拼出工作根下某个相对路径的完整 URL。
  ///
  /// [relPath] 一律相对工作根；不允许 `..` 穿越到根目录之外。
  String fullUrl(String relPath) {
    final clean = _cleanRel(relPath);
    return clean.isEmpty ? _workRoot : '$_workRoot$clean';
  }

  static String _cleanRel(String rel) {
    var s = rel.trim().replaceAll(r'\', '/');
    while (s.startsWith('/')) {
      s = s.substring(1);
    }
    while (s.endsWith('/') && s.isNotEmpty) {
      s = s.substring(0, s.length - 1);
    }
    // 目录路径在调用处通过 fullUrlDir 补尾斜杠。
    return s;
  }

  /// 目录 URL（带尾斜杠）。
  String fullUrlDir(String relPath) {
    final clean = _cleanRel(relPath);
    return clean.isEmpty ? _workRoot : '$_workRoot$clean/';
  }

  /// 测试连接：列工作根。成功即通过（串行为空也 OK）。
  Future<void> test() async {
    if (!connection.configured) {
      throw const LegadoException(ErrorCode.sourceEmpty, '尚未配置 WebDAV');
    }
    await _propfind('');
  }

  /// 列目录（depth=1），返回相对工作根的条目。
  Future<List<WebDavEntry>> list(String relPath) =>
      _propfind(relPath, depth: 1, includeSelf: false);

  /// 递归扫描目录下的书籍文件，返回相对工作根的路径。
  Future<List<WebDavEntry>> scanBooks(String relPath,
      {Set<String> extensions = bookExtensions}) async {
    final out = <WebDavEntry>[];
    await _walk(relPath, out, extensions, 0);
    return out;
  }

  static const Set<String> bookExtensions = <String>{
    'txt', 'epub', 'umd', 'pdf', 'mobi', 'azw3', 'azw',
  };

  Future<void> _walk(
    String rel,
    List<WebDavEntry> out,
    Set<String> extensions,
    int depth,
  ) async {
    if (depth > 12) return; // 防止病态目录无限递归
    final entries = await list(rel);
    for (final e in entries) {
      if (e.isDir) {
        await _walk(e.path, out, extensions, depth + 1);
      } else {
        final ext = _extensionOf(e.name);
        if (extensions.contains(ext)) out.add(e);
      }
    }
  }

  static String _extensionOf(String name) {
    final i = name.lastIndexOf('.');
    return i < 0 ? '' : name.substring(i + 1).toLowerCase();
  }

  Future<List<WebDavEntry>> _propfind(
    String relPath, {
    int depth = 1,
    bool includeSelf = false,
  }) async {
    const body = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
  <d:displayname/>
  <d:resourcetype/>
  <d:getcontentlength/>
  <d:creationdate/>
  <d:getlastmodified/>
  <d:getcontenttype/>
</d:prop></d:propfind>''';
    final url = fullUrlDir(relPath);
    final resp = await _net.send(HttpRequest(
      Uri.parse(url),
      method: 'PROPFIND',
      headers: <String, String>{
        ..._authHeaders,
        'depth': '$depth',
        'content-type': 'application/xml; charset=utf-8',
      },
      body: utf8.encode(body),
    ));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw LegadoException(ErrorCode.authRequired,
            'WebDAV 认证失败: HTTP ${resp.statusCode}');
      }
      throw LegadoException(ErrorCode.netTimeout,
          'WebDAV 列目录失败: HTTP ${resp.statusCode}');
    }
    return _parsePropfind(resp.text(), url);
  }

  /// 解析 PROPFIND 的 XML（对齐 Kotlin `WebDav.parseBody`）。
  List<WebDavEntry> _parsePropfind(String body, String requestUrl) {
    final out = <WebDavEntry>[];
    xml.XmlDocument document;
    try {
      document = xml.XmlDocument.parse(body);
    } on xml.XmlParserException catch (e) {
      _log.warning('WebDAV PROPFIND XML 解析失败: $e');
      return out;
    }
    final requestUri = Uri.parse(requestUrl);
    // findAllElements 匹配的是带前缀的限定名（`d:response`），而不同服务器前缀各异，
    // 所以按 localName 遍历（与 Kotlin findNS 的语义一致）。
    final responses = document.descendants
        .whereType<xml.XmlElement>()
        .where((e) => e.name.local == 'response')
        .toList();
    for (final response in responses) {
      final hrefNode = _child(response, 'href');
      if (hrefNode == null) continue;
      final href = hrefNode.innerText.trim();
      // href 可能是绝对 URL 或相对路径，且 path 段可能含百分号编码（%20）。
      // Uri.resolve 会保留编码，取 pathSegments 时再逐段 decode。
      late final Uri hrefUri;
      try {
        hrefUri = requestUri.resolve(href);
      } catch (_) {
        continue;
      }
      final lastSeg = hrefUri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? '';
      final nameRaw = _decodePathSegment(lastSeg);
      final isDir = href.endsWith('/') ||
          _child(response, 'collection') != null;
      final displayName = _child(response, 'displayname')?.innerText.trim();
      final size = int.tryParse(_child(response, 'getcontentlength')?.innerText.trim() ?? '') ?? 0;
      final modTime = _parseHttpDate(_child(response, 'getlastmodified')?.innerText.trim());
      final contentType = _child(response, 'getcontenttype')?.innerText.trim() ?? '';

      // 条目相对工作根的路径：把绝对 href 转成相对 workRoot。
      final rel = _relativeToWorkRoot(hrefUri.path);
      if (rel == null) continue;
      if (rel.isEmpty && isDir) continue; // 跳过工作根自身
      out.add(WebDavEntry(
        path: rel + (isDir ? '/' : ''),
        name: (displayName != null && displayName.isNotEmpty ? displayName : nameRaw),
        isDir: isDir,
        size: size,
        modTime: modTime,
        contentType: contentType,
      ));
    }
    return out;
  }

  static String _decodePathSegment(String s) {
    try {
      return Uri.decodeComponent(s);
    } catch (_) {
      return s;
    }
  }

  /// 返回 href 的路径相对工作根的部分；不在工作根下返回 null。
  String? _relativeToWorkRoot(String hrefPath) {
    final root = Uri.parse(_workRoot).path;
    final p = hrefPath;
    if (!p.startsWith(root)) return null;
    var rel = p.substring(root.length);
    while (rel.startsWith('/')) {
      rel = rel.substring(1);
    }
    while (rel.endsWith('/') && rel.isNotEmpty) {
      rel = rel.substring(0, rel.length - 1);
    }
    // 逐段解码，得到与 Kotlin URLDecoder.decodeForPath 一致的相对路径。
    if (rel.isNotEmpty) {
      rel = rel.split('/').map(_decodePathSegment).join('/');
    }
    return rel;
  }

  /// 按 local-name 查子节点（兼容 `<d:resourcetype>` / `<resourcetype>` 与默认命名空间）。
  static xml.XmlElement? _child(xml.XmlElement parent, String localName) {
    for (final node in parent.childElements) {
      if (node.name.local == localName) return node;
    }
    // getlastmodified 等可能在嵌套里（resourcetype>collection）
    for (final node in parent.descendants) {
      if (node is xml.XmlElement && node.name.local == localName) return node;
    }
    return null;
  }

  /// RFC 1123（HTTP 日期，如 `Wed, 21 Oct 2015 07:28:00 GMT`）。
  /// Dart 没有内置解析器，手动兜住 WebDAV 常见的这一种格式即可。
  static int _parseHttpDate(String? value) {
    if (value == null || value.isEmpty) return 0;
    final dt = DateTime.tryParse(value);
    if (dt != null) return dt.millisecondsSinceEpoch;
    final m = RegExp(
      r'^\w{3},\s*(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(value);
    if (m == null) return 0;
    const months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months.indexOf(m.group(2)!) + 1;
    if (month == 0) return 0;
    return DateTime.utc(
      int.parse(m.group(3)!),
      month,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    ).millisecondsSinceEpoch;
  }

  /// 下载文件字节（GET）。用于导入书籍与下载备份。
  Future<List<int>> download(String relPath,
      {void Function(int done, int total)? onProgress}) async {
    final url = fullUrl(relPath);
    final resp = await _net.send(HttpRequest(
      Uri.parse(url),
      method: 'GET',
      headers: _authHeaders,
    ));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw LegadoException(ErrorCode.authRequired,
            'WebDAV 下载失败: HTTP ${resp.statusCode}');
      }
      throw LegadoException(ErrorCode.notFound,
          'WebDAV 文件不存在: $relPath (HTTP ${resp.statusCode})');
    }
    onProgress?.call(resp.bodyBytes.length, resp.bodyBytes.length);
    return resp.bodyBytes;
  }

  /// 上传字节（PUT）。目录不存在时自动 MKCOL。
  Future<void> upload(String relPath, List<int> bytes,
      {String contentType = 'application/octet-stream'}) async {
    final url = fullUrl(relPath);
    final resp = await _net.send(HttpRequest(
      Uri.parse(url),
      method: 'PUT',
      headers: <String, String>{
        ..._authHeaders,
        'content-type': contentType,
      },
      body: bytes,
      timeout: const Duration(minutes: 5),
    ));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw LegadoException(ErrorCode.authRequired,
            'WebDAV 上传失败: HTTP ${resp.statusCode}');
      }
      throw LegadoException(ErrorCode.netTimeout,
          'WebDAV 上传失败: HTTP ${resp.statusCode}');
    }
  }

  /// 建目录（MKCOL），409（已存在）视为成功。
  Future<void> makeDir(String relPath) async {
    final url = fullUrlDir(relPath);
    final resp = await _net.send(HttpRequest(
      Uri.parse(url),
      method: 'MKCOL',
      headers: _authHeaders,
    ));
    if (resp.statusCode == 405 || resp.statusCode == 409) return; // 已存在
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw LegadoException(ErrorCode.netTimeout,
          'WebDAV 建目录失败: HTTP ${resp.statusCode}');
    }
  }

  /// 删除文件或目录（DELETE）。
  Future<void> delete(String relPath) async {
    final url = relPath.endsWith('/') ? fullUrlDir(relPath) : fullUrl(relPath);
    final resp = await _net.send(HttpRequest(
      Uri.parse(url),
      method: 'DELETE',
      headers: _authHeaders,
    ));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      if (resp.statusCode == 404) return; // 幂等
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw LegadoException(ErrorCode.authRequired,
            'WebDAV 删除失败: HTTP ${resp.statusCode}');
      }
      throw LegadoException(ErrorCode.netTimeout,
          'WebDAV 删除失败: HTTP ${resp.statusCode}');
    }
  }
}
