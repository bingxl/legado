/// 进程级 Cookie 容器。
///
/// 语义对齐 RFC 6265（浏览器行为），而不是原版 `CookieStore.kt` 那种
/// 「按二级域名存一整串」的做法：
///
/// - 原版把 cookie 按「域名」聚合为一个字符串，同名不同 path 的 cookie 会互相覆盖。
///   书源站点的登录态经常挂在 `/` 上、会话挂在 `/api` 上，聚合存法会让后写的
///   把先写的挤掉，表现为「登录了但抓不到正文」。
/// - 这里按 `domain + path + name` 三元组独立存，等价于浏览器的 cookie jar。
///
/// 域匹配 / path 匹配 / 过期判定都按 RFC 6265 §5.1 实现，`__Host-` / `__Secure-`
/// 前缀也做校验（浏览器会拒收，不校验就会出现「本地有 cookie 但服务端不认」）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 单条 cookie。
class Cookie {
  Cookie({
    required this.name,
    required this.value,
    required this.domain,
    this.hostOnly = false,
    this.path = '/',
    this.expires,
    this.maxAge,
    this.secure = false,
    this.httpOnly = false,
    this.sameSite,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// cookie 名。
  final String name;

  /// cookie 值（已去掉包裹的引号）。
  final String value;

  /// 作用域域名，小写，不含前导点。
  final String domain;

  /// 是否为 host-only（Set-Cookie 里没有 Domain 属性）。
  ///
  /// host-only 的 cookie 只回传给完全相同的 host，子域拿不到。
  final bool hostOnly;

  /// 作用域路径。
  final String path;

  /// 绝对过期时间（Expires 属性）。
  final DateTime? expires;

  /// 相对有效期（Max-Age 属性），优先级高于 [expires]。
  final Duration? maxAge;

  /// 是否只在 https 下回传。
  final bool secure;

  /// 是否禁止 JS 读取（HttpOnly）。
  ///
  /// 纯 Dart 侧没有 JS 沙箱边界，这个字段只用于持久化与 WebView 导入，
  /// 不参与发送判定。
  final bool httpOnly;

  /// SameSite 属性原样保留（`Lax`/`Strict`/`None`）。
  ///
  /// 我们没有浏览器那种跨站请求模型，不按它过滤，只保证导入导出不丢信息。
  final String? sameSite;

  /// 创建时间。RFC 6265 要求同名 cookie 按创建时间排序。
  final DateTime createdAt;

  /// 是否为会话 cookie（没有 Expires / Max-Age，进程退出即失效）。
  bool get isSession => expires == null && maxAge == null;

  /// 绝对失效时间。会话 cookie 返回 null。
  DateTime? get expiryTime {
    if (maxAge != null) return createdAt.add(maxAge!);
    return expires;
  }

  /// 是否已过期。[now] 仅供测试注入时钟。
  bool isExpired([DateTime? now]) {
    final at = now ?? DateTime.now();
    final t = expiryTime;
    if (t == null) return false;
    return !t.isAfter(at);
  }

  /// `name=value`，用于拼 Cookie 请求头。
  String get pair => '$name=$value';

  Map<String, Object?> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'hostOnly': hostOnly,
    'path': path,
    'expires': expires?.toUtc().toIso8601String(),
    'maxAge': maxAge?.inSeconds,
    'secure': secure,
    'httpOnly': httpOnly,
    'sameSite': sameSite,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static Cookie? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final value = raw['value'];
    final domain = raw['domain'];
    if (name is! String || value is! String || domain is! String) return null;
    final maxAge = raw['maxAge'];
    final createdAt = raw['createdAt'];
    final expires = raw['expires'];
    return Cookie(
      name: name,
      value: value,
      domain: domain.toLowerCase(),
      hostOnly: raw['hostOnly'] == true,
      path: raw['path'] is String && (raw['path'] as String).isNotEmpty
          ? raw['path'] as String
          : '/',
      expires: expires is String ? DateTime.tryParse(expires)?.toLocal() : null,
      maxAge: maxAge is int && maxAge > 0 ? Duration(seconds: maxAge) : null,
      secure: raw['secure'] == true,
      httpOnly: raw['httpOnly'] == true,
      sameSite: raw['sameSite'] is String ? raw['sameSite'] as String : null,
      createdAt: createdAt is String
          ? (DateTime.tryParse(createdAt)?.toLocal() ?? DateTime.now())
          : DateTime.now(),
    );
  }

  @override
  String toString() =>
      'Cookie($name=$value, domain=$domain, path=$path, hostOnly=$hostOnly)';
}

/// 进程级 cookie 容器。
///
/// 一个进程建议只用一个实例（[NetClient] 默认自带），
/// 因为 Cloudflare 的 `cf_clearance`、书源登录态都是跨请求共享的。
class CookieStore {
  CookieStore({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  /// domain → cookies。域名小写、无前导点。
  final Map<String, List<Cookie>> _byDomain = {};

  /// 读锁意义上的「版本号」：修改后自增，方便上层判断是否需要落盘。
  int _revision = 0;

  int get revision => _revision;

  /// cookie 总条数（含已过期但未清理的）。
  int get length {
    var n = 0;
    for (final list in _byDomain.values) {
      n += list.length;
    }
    return n;
  }

  bool get isEmpty => length == 0;

  /// 当前所有 cookie 的快照（调试 / 持久化用）。
  List<Cookie> get all {
    final out = <Cookie>[];
    for (final list in _byDomain.values) {
      out.addAll(list);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 读取
  // ---------------------------------------------------------------------------

  /// 找出应当发给 [uri] 的全部 cookie，按 RFC 6265 §5.4 排序：
  /// path 长的在前，同长度按创建时间早的在前。
  List<Cookie> cookiesFor(Uri uri, {DateTime? now}) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return const [];
    final at = now ?? _clock();
    final reqPath = uri.path.isEmpty ? '/' : uri.path;
    final secureChannel = uri.scheme == 'https';
    final matched = <Cookie>[];

    for (final entry in _byDomain.entries) {
      final domain = entry.key;
      if (!_domainMatches(host, domain)) continue;
      for (final c in entry.value) {
        if (c.isExpired(at)) continue;
        if (c.hostOnly && c.domain != host) continue;
        if (c.secure && !secureChannel) continue;
        if (!_pathMatches(reqPath, c.path)) continue;
        matched.add(c);
      }
    }

    matched.sort((a, b) {
      final byPath = b.path.length.compareTo(a.path.length);
      if (byPath != 0) return byPath;
      return a.createdAt.compareTo(b.createdAt);
    });
    return matched;
  }

  /// 拼出 `Cookie` 请求头的值；没有可用 cookie 时返回 null。
  String? getCookieHeader(Uri uri, {DateTime? now}) {
    final list = cookiesFor(uri, now: now);
    if (list.isEmpty) return null;
    return list.map((c) => c.pair).join('; ');
  }

  /// 取单个 cookie 的值（不区分 path，取最「贴近」的那条）。
  String? cookieValue(Uri uri, String name, {DateTime? now}) {
    for (final c in cookiesFor(uri, now: now)) {
      if (c.name == name) return c.value;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // 写入
  // ---------------------------------------------------------------------------

  /// 写入一个响应里的全部 `Set-Cookie` 头。
  ///
  /// 一条不合法不影响其余条目：浏览器也是逐条丢弃，不能因为站点发了个畸形
  /// cookie 就把整批登录态都扔了。
  void setFromResponse(Uri uri, List<String> setCookieHeaders) {
    for (final raw in setCookieHeaders) {
      setCookie(uri, raw);
    }
  }

  /// 写入单条 `Set-Cookie` 头，返回落地的 cookie（被拒收或删除指令时返回 null）。
  Cookie? setCookie(Uri uri, String setCookieHeader) {
    final parsed = parseSetCookie(uri, setCookieHeader, now: _clock());
    if (parsed == null) return null;
    _put(parsed);
    if (parsed.isExpired(_clock())) return null;
    return parsed;
  }

  /// 直接写入（覆盖同名同域同路径的那条）。
  void put(Cookie cookie) => _put(cookie);

  /// 用命名值构造并写入一条 host-only cookie（供 WebView 导入 / 测试使用）。
  Cookie putNameValue(
    Uri uri,
    String name,
    String value, {
    bool secure = false,
    String? path,
  }) {
    final cookie = Cookie(
      name: name,
      value: value,
      domain: uri.host.toLowerCase(),
      hostOnly: true,
      path: path ?? _defaultPath(uri.path),
      secure: secure,
      createdAt: _clock(),
    );
    _put(cookie);
    return cookie;
  }

  void _put(Cookie cookie) {
    if (cookie.isExpired(_clock())) {
      _removeExact(cookie.domain, cookie.name, cookie.path);
      return;
    }
    final list = _byDomain.putIfAbsent(cookie.domain, () => <Cookie>[]);
    list.removeWhere((c) => c.name == cookie.name && c.path == cookie.path);
    // 创建时间统一由容器盖章，保证严格单调递增。
    // 同一毫秒内写入多条 cookie 时，浏览器按创建顺序排序；DateTime.now() 的
    // 精度不够，排序会变成随机顺序（Dart 的 sort 不稳定），导致 Cookie 头
    // 每次请求都不一样——某些站点的签名校验会因此失败。
    final stamped = Cookie(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      hostOnly: cookie.hostOnly,
      path: cookie.path,
      expires: cookie.expires,
      maxAge: cookie.maxAge,
      secure: cookie.secure,
      httpOnly: cookie.httpOnly,
      sameSite: cookie.sameSite,
      createdAt: _nextStamp(),
    );
    list.add(stamped);
    _revision++;
  }

  DateTime? _lastStamp;

  DateTime _nextStamp() {
    final now = _clock();
    final last = _lastStamp;
    final stamp = last != null && !now.isAfter(last)
        ? last.add(const Duration(microseconds: 1))
        : now;
    _lastStamp = stamp;
    return stamp;
  }

  /// 删除某域名下指定名字的 cookie（不区分 path）。
  void removeKey(String domain, String name) {
    final key = domain.toLowerCase();
    final list = _byDomain[key];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((c) => c.name == name);
    if (list.isEmpty) _byDomain.remove(key);
    if (list.length != before) _revision++;
  }

  /// 删除发给 [uri] 的全部 cookie（含子域）。
  ///
  /// 对齐原版 `CookieStore.removeCookie(url)` 的效果：清掉该站点整份登录态。
  /// 双向匹配是必要的：`a.com` 上清登录态时，`www.a.com` 与 `m.a.com` 下
  /// 各自 host-only 的 cookie 也得一起清，否则「退出登录」后子域仍然带着旧
  /// 会话继续抓正文。
  void removeAll(Uri uri) {
    final host = uri.host.toLowerCase();
    final doomed = <String>[];
    for (final entry in _byDomain.entries) {
      final domain = entry.key;
      if (domain == host ||
          _domainMatches(host, domain) ||
          _domainMatches(domain, host)) {
        doomed.add(domain);
      }
    }
    for (final d in doomed) {
      _byDomain.remove(d);
    }
    if (doomed.isNotEmpty) _revision++;
  }

  /// 清空全部 cookie。
  void clear() {
    if (_byDomain.isEmpty) return;
    _byDomain.clear();
    _revision++;
  }

  /// 清理已过期条目，返回被清掉的条数。
  int removeExpired({DateTime? now}) {
    final at = now ?? _clock();
    var removed = 0;
    final emptyKeys = <String>[];
    for (final entry in _byDomain.entries) {
      final list = entry.value;
      final before = list.length;
      list.removeWhere((c) => c.isExpired(at));
      removed += before - list.length;
      if (list.isEmpty) emptyKeys.add(entry.key);
    }
    for (final k in emptyKeys) {
      _byDomain.remove(k);
    }
    if (removed > 0) _revision++;
    return removed;
  }

  // ---------------------------------------------------------------------------
  // WebView 导入
  // ---------------------------------------------------------------------------

  /// 从 WebView / 浏览器内核导入 cookie。
  ///
  /// 为什么单独一个入口而不是复用 [setFromResponse]：WebView 拿到的 cookie
  /// 是「内核里的完整集合」，不是 `Set-Cookie` 头。硬套 `Set-Cookie` 语义会把
  /// 没有 Expires 的项当成会话 cookie、并把 host-only 补成 Domain，导致登录态
  /// 被顶掉。这里直接按 cookie 对象写入，域与 path 由调用方（或 [uri]）决定。
  ///
  /// [replaceDomain] 为 true 时先清空该 host 的旧 cookie——WebView 是权威来源，
  /// 残留的旧值（尤其是过期的 `cf_clearance`）会让验证反复失败。
  void replaceFromWebView(
    Uri uri,
    List<Cookie> cookies, {
    bool replaceDomain = true,
  }) {
    if (replaceDomain) {
      _byDomain.remove(uri.host.toLowerCase());
    }
    for (final c in cookies) {
      _put(c);
    }
    _revision++;
  }

  /// 导入 `"a=1; b=2"` 形式的 cookie 串（`document.cookie` / `Cookie` 头）。
  ///
  /// 每对都按 host-only、[uri] 的默认 path 落地，除非 [path] 显式给出。
  void importCookieHeader(Uri uri, String header, {String? path}) {
    for (final pair in _splitCookiePairs(header)) {
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = _unquote(pair.substring(eq + 1).trim());
      if (name.isEmpty) continue;
      putNameValue(uri, name, value, path: path, secure: uri.scheme == 'https');
    }
  }

  // ---------------------------------------------------------------------------
  // 持久化
  // ---------------------------------------------------------------------------

  /// 序列化为纯内存结构（格式与 [save] 落盘的 JSON 完全一致）。
  ///
  /// 服务层拿它接数据库的 `cookies` 表：
  /// `jsonEncode(store.toJson())` 存一列，读出来 `jsonDecode` 后 [fromJson]。
  /// 这样存储层不必 import 本文件的具体字段，只要认这个 map 结构。
  Map<String, Object?> toJson() {
    final cookies = <Map<String, Object?>>[];
    for (final c in all) {
      cookies.add(c.toJson());
    }
    return {
      'version': 1,
      'savedAt': _clock().toUtc().toIso8601String(),
      'cookies': cookies,
    };
  }

  /// 从 [toJson] 的结构**合并**加载（不清空现有 cookie）。
  ///
  /// 合并而不是替换：同一个进程里可能既有从数据库读出来的登录态，
  /// 又有 WebView 刚写进来的 `cf_clearance`，替换会丢掉后者。
  /// 需要整份替换时先调 [clear]。
  void fromJson(Map<String, Object?> json) {
    final list = json['cookies'];
    if (list is! List) return;
    for (final item in list) {
      final c = Cookie.fromJson(item);
      if (c != null) _put(c);
    }
  }

  /// 从 JSON 文件加载。
  ///
  /// 文件不存在不算错误（首次运行）；解析失败也不抛，宁可丢 cookie 也不能让
  /// 整个内核起不来。[path] 由调用方决定。
  Future<void> load(String path) async {
    if (path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;
    try {
      final text = await file.readAsString();
      if (text.trim().isEmpty) return;
      final root = jsonDecode(text);
      if (root is Map<String, Object?>) {
        fromJson(root);
      } else if (root is Map) {
        fromJson(root.cast<String, Object?>());
      }
    } catch (_) {
      // 损坏的 cookie 文件：保持现状，交给用户下次保存时覆盖。
    }
  }

  /// 保存到 JSON 文件。父目录不存在时自动创建。
  Future<void> save(String path) async {
    if (path.isEmpty) return;
    final file = File(path);
    final dir = file.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  // ---------------------------------------------------------------------------
  // 内部：RFC 6265 解析
  // ---------------------------------------------------------------------------

  void _removeExact(String domain, String name, String path) {
    final list = _byDomain[domain];
    if (list == null) return;
    list.removeWhere((c) => c.name == name && c.path == path);
    if (list.isEmpty) _byDomain.remove(domain);
    _revision++;
  }
}

/// 解析一条 `Set-Cookie`。
///
/// 返回 null 表示应当整条丢弃（语法非法、域不匹配、前缀约束不满足）。
///
/// 经典坑：`Expires=Wed, 21 Oct 2015 07:28:00 GMT` 里带逗号。
/// 按逗号切分会把日期劈成两半，把 `21 Oct 2015 07:28:00 GMT` 当成一个属性。
/// 这里只按分号切分属性，逗号原样留在值里。
Cookie? parseSetCookie(Uri uri, String header, {DateTime? now}) {
  if (header.isEmpty) return null;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  final at = now ?? DateTime.now();

  final parts = _splitAttributes(header);
  if (parts.isEmpty) return null;

  final first = parts.first;
  final eq = first.indexOf('=');
  if (eq <= 0) return null;
  final name = first.substring(0, eq).trim();
  if (name.isEmpty) return null;
  final rawValue = first.substring(eq + 1).trim();
  final value = _unquote(rawValue);

  String? domainAttr;
  var pathAttr = '';
  DateTime? expires;
  Duration? maxAge;
  var secure = false;
  var httpOnly = false;
  String? sameSite;

  for (var i = 1; i < parts.length; i++) {
    final attr = parts[i];
    final idx = attr.indexOf('=');
    final key = (idx < 0 ? attr : attr.substring(0, idx)).trim().toLowerCase();
    final val = idx < 0 ? '' : attr.substring(idx + 1).trim();
    switch (key) {
      case 'domain':
        if (val.isNotEmpty) {
          domainAttr = val.toLowerCase();
          if (domainAttr.startsWith('.')) {
            domainAttr = domainAttr.substring(1);
          }
        }
      case 'path':
        pathAttr = val;
      case 'expires':
        expires = parseCookieDate(val);
      case 'max-age':
        final secs = int.tryParse(val);
        if (secs != null) maxAge = Duration(seconds: secs);
      case 'secure':
        secure = true;
      case 'httponly':
        httpOnly = true;
      case 'samesite':
        if (val.isNotEmpty) sameSite = val;
    }
  }

  // 前缀约束（RFC 6265bis §4.1.3）：浏览器拒收，我们也拒收，
  // 否则会出现「本地存了但服务端不认」的诡异现象。
  if (name.startsWith('__Host-')) {
    if (!secure || domainAttr != null || pathAttr != '/') return null;
  } else if (name.startsWith('__Secure-')) {
    if (!secure) return null;
  }

  var hostOnly = true;
  var domain = host;
  if (domainAttr != null && domainAttr.isNotEmpty) {
    // 服务端下发的 Domain 必须覆盖当前 host，否则是伪造的（或配置错误）。
    if (!_domainMatches(host, domainAttr)) return null;
    domain = domainAttr;
    hostOnly = false;
  }

  final path = pathAttr.isNotEmpty && pathAttr.startsWith('/')
      ? pathAttr
      : _defaultPath(uri.path);

  final cookie = Cookie(
    name: name,
    value: value,
    domain: domain,
    hostOnly: hostOnly,
    path: path,
    expires: expires,
    maxAge: maxAge,
    secure: secure,
    httpOnly: httpOnly,
    sameSite: sameSite,
    createdAt: at,
  );

  // Max-Age<=0 或 Expires 已过期 = 删除指令。返回 cookie 让调用方走删除分支。
  return cookie;
}

/// 解析 cookie 的日期属性。
///
/// 不做严格格式匹配而是按 token 归类，因为现实里有三种格式并存：
/// - `Wed, 21 Oct 2015 07:28:00 GMT`（RFC 1123）
/// - `Wednesday, 21-Oct-15 07:28:00 GMT`（RFC 850，两位年份）
/// - `Wed Oct 21 07:28:00 2015`（asctime）
DateTime? parseCookieDate(String raw) {
  if (raw.isEmpty) return null;
  final tokens = raw
      .split(RegExp(r'[\s,\-]+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return null;

  int? hour;
  int? minute;
  int? second;
  int? day;
  int? month;
  int? year;

  const months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  final timeRe = RegExp(r'^(\d{1,2}):(\d{2}):(\d{2})$');
  for (final t in tokens) {
    final tm = timeRe.firstMatch(t);
    if (tm != null) {
      hour = int.parse(tm.group(1)!);
      minute = int.parse(tm.group(2)!);
      second = int.parse(tm.group(3)!);
      continue;
    }
    final lower = t.toLowerCase();
    final m = months[lower.length >= 3 ? lower.substring(0, 3) : lower];
    if (m != null) {
      month = m;
      continue;
    }
    final n = int.tryParse(t);
    if (n == null) continue;
    if (t.length == 4 && n >= 1601 && n <= 9999) {
      year = n;
    } else if (t.length <= 2 && day == null) {
      day = n;
    } else if (t.length <= 2 && year == null) {
      year = n < 70 ? 2000 + n : 1900 + n;
    }
  }

  if (hour == null || minute == null || second == null) return null;
  if (day == null || month == null || year == null) return null;
  if (hour > 23 || minute > 59 || second > 59) return null;
  if (day < 1 || day > 31 || year < 1601) return null;
  return DateTime.utc(year, month, day, hour, minute, second);
}

/// 按分号切分属性，但保留引号内的分号（`value="a;b"` 这种合法但不常见的写法）。
List<String> _splitAttributes(String header) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < header.length; i++) {
    final ch = header[i];
    if (ch == '"') {
      inQuotes = !inQuotes;
      buf.write(ch);
      continue;
    }
    if (ch == ';' && !inQuotes) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  out.add(buf.toString());
  return [for (final s in out) if (s.trim().isNotEmpty) s.trim()];
}

/// 拆分 `"a=1; b=2"` 为 `["a=1", "b=2"]`。
List<String> _splitCookiePairs(String header) {
  final out = <String>[];
  for (final part in header.split(';')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    // 跳过属性形态的片段（WebView 偶尔会把 Path/Secure 一起带回来）。
    final lower = p.toLowerCase();
    if (lower.startsWith('path=') ||
        lower.startsWith('domain=') ||
        lower.startsWith('expires=') ||
        lower.startsWith('max-age=') ||
        lower == 'secure' ||
        lower == 'httponly') {
      continue;
    }
    out.add(p);
  }
  return out;
}

String _unquote(String v) {
  if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
    return v.substring(1, v.length - 1);
  }
  return v;
}

/// host 是否落在 domain 内（RFC 6265 §5.1.3）。
///
/// `domain` 不含前导点：`www.a.com` 对 `a.com` 为真，对 `b.com` 为假。
bool _domainMatches(String host, String domain) {
  if (host == domain) return true;
  if (domain.isEmpty) return false;
  return host.endsWith('.$domain');
}

/// 请求路径是否命中 cookie 的 path（RFC 6265 §5.1.4）。
///
/// `/a/b` 命中 `/a/b` 与 `/a/b/c`，但不命中 `/a/bc`——前缀匹配后必须紧跟 `/`。
bool _pathMatches(String requestPath, String cookiePath) {
  if (cookiePath.isEmpty) return true;
  if (requestPath == cookiePath) return true;
  if (!requestPath.startsWith(cookiePath)) return false;
  if (cookiePath.endsWith('/')) return true;
  return requestPath[cookiePath.length] == '/';
}

/// 缺省 path（RFC 6265 §5.1.4）：去掉最后一个 `/` 及其右边的内容。
String _defaultPath(String uriPath) {
  if (uriPath.isEmpty || !uriPath.startsWith('/')) return '/';
  final idx = uriPath.lastIndexOf('/');
  if (idx <= 0) return '/';
  return uriPath.substring(0, idx);
}
