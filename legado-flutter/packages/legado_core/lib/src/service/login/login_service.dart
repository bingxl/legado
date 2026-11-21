/// 书源登录域。
///
/// 三种登录方式（对齐 Kotlin `BookSourceLogin`）：
///
/// 1. **js**：`loginUrl` 里带 `<js>` / `@js:`，脚本自己发请求（`java.post` 等）。
///    cookie 由网络层的 CookieStore 自动收下。
/// 2. **request**：`loginUrl` 是 `地址,{"method":"POST","body":"..."}` 形态的
///    URL 规则，按规则发一次请求即为登录。
/// 3. **page**：`loginUrl` 只是个登录页地址，必须有人工交互。
///
/// 宿主没有内嵌浏览器时，page 方式拿不到 cookie —— 这时把地址回给 UI，
/// 并让用户从浏览器复制请求头粘贴回来（[LoginService.saveHeader]）。
/// 这不是偷懒：桌面端装 WebView 的收益远小于「粘贴一次就能用」的成本。
library;

import 'dart:convert';

import 'package:logging/logging.dart';

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../../rules/rules.dart';
import '../../store/store.dart';
import '../source/source_fetch_service.dart';

final Logger _log = Logger('legado.login');

/// 登录表单里的一个字段（对应 `loginUi.chars[]`）。
class LoginFieldView {
  const LoginFieldView({
    required this.name,
    required this.type,
    required this.action,
  });

  final String name;

  /// `text` / `password` / `button` / `select` 等，原样透传。
  final String type;

  /// 按钮绑定的动作脚本（非按钮为空）。
  final String action;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'type': type,
        'action': action,
      };
}

/// 登录面板的全部信息。
class LoginProfileView {
  const LoginProfileView({
    required this.sourceId,
    required this.sourceName,
    required this.sourceUrl,
    required this.sourceType,
    required this.kind,
    required this.loginUrl,
    required this.fields,
    required this.info,
    required this.hasCookie,
    required this.cookieMask,
    required this.header,
    required this.checkJs,
    required this.updatedAt,
  });

  final int sourceId;
  final String sourceName;
  final String sourceUrl;
  final int sourceType;

  /// `js` / `request` / `page` / `header` / `none`。
  final String kind;
  final String loginUrl;
  final List<LoginFieldView> fields;
  final String info;
  final bool hasCookie;
  final String cookieMask;

  /// 用户粘贴的请求头原文。
  final String header;
  final String checkJs;
  final int updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'sourceId': sourceId,
        'sourceName': sourceName,
        'sourceUrl': sourceUrl,
        'sourceType': sourceType,
        'kind': kind,
        'loginUrl': loginUrl,
        'fields': [for (final field in fields) field.toJson()],
        'info': info,
        'hasCookie': hasCookie,
        'cookieMask': cookieMask,
        'header': header,
        'checkJs': checkJs,
        'updatedAt': updatedAt,
      };
}

/// 一次登录/动作的结果。
class LoginResultView {
  const LoginResultView({
    required this.ok,
    required this.loggedIn,
    required this.message,
    this.logs = const [],
    this.output = '',
    this.openUrl = '',
    this.cookieMask = '',
  });

  final bool ok;
  final bool loggedIn;
  final String message;

  /// 日志行。脚本引擎的 console 输出是进程级回调，没法按次收集，
  /// 这里保留字段是为了契约稳定（将来接上按次回调就不用改协议）。
  final List<String> logs;

  /// 脚本返回值（转成字符串）。
  final String output;

  /// page 方式下需要用户打开的地址。
  final String openUrl;
  final String cookieMask;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'loggedIn': loggedIn,
        'message': message,
        'logs': logs,
        'output': output,
        'openUrl': openUrl,
        'cookieMask': cookieMask,
      };
}

/// 登录探测结果。
class LoginProbeView {
  const LoginProbeView({
    required this.needLogin,
    required this.detail,
    required this.statusCode,
    required this.url,
  });

  final bool needLogin;
  final String detail;
  final int statusCode;
  final String url;

  Map<String, Object?> toJson() => <String, Object?>{
        'needLogin': needLogin,
        'detail': detail,
        'statusCode': statusCode,
        'url': url,
      };
}

/// 登录域服务。
class LoginService {
  LoginService({required StoreDaos daos, required SourceFetchService fetch})
      : _daos = daos,
        _fetch = fetch;

  final StoreDaos _daos;
  final SourceFetchService _fetch;

  // ----------------------------------------------------------------------
  // 读
  // ----------------------------------------------------------------------

  LoginProfileView profile(int sourceId) {
    final source = _fetch.requireSource(sourceId);
    final record = _daos.sourceLogin.get(source.bookSourceUrl);
    final loginUrl = (source.loginUrl ?? '').trim();
    final hasCookie = _hasCookie(source);
    return LoginProfileView(
      sourceId: sourceId,
      sourceName: source.bookSourceName,
      sourceUrl: source.bookSourceUrl,
      sourceType: source.bookSourceType,
      kind: _kindOf(loginUrl),
      loginUrl: loginUrl,
      fields: _fieldsOf(source.loginUi),
      info: record?.info ?? '',
      hasCookie: hasCookie,
      cookieMask: _cookieMask(source),
      header: record?.header ?? '',
      checkJs: (source.loginCheckJs ?? '').trim(),
      updatedAt: record?.updatedAt ?? 0,
    );
  }

  String header(int sourceId) =>
      _daos.sourceLogin.get(_fetch.requireSource(sourceId).bookSourceUrl)?.header ??
      '';

  // ----------------------------------------------------------------------
  // 写
  // ----------------------------------------------------------------------

  /// 登录。按 [LoginProfileView.kind] 分派。
  Future<LoginResultView> login(int sourceId, Map<String, String> form) async {
    final source = _fetch.requireSource(sourceId);
    final loginUrl = (source.loginUrl ?? '').trim();
    if (loginUrl.isEmpty) {
      return LoginResultView(
        ok: false,
        loggedIn: _hasCookie(source),
        message: '该书写源没有配置登录地址，请粘贴浏览器请求头',
        cookieMask: _cookieMask(source),
      );
    }
    switch (_kindOf(loginUrl)) {
      case 'js':
        return _runScript(source, _scriptOf(loginUrl), form);
      case 'request':
        return _loginByRequest(source, loginUrl, form);
      default:
        return LoginResultView(
          ok: true,
          loggedIn: false,
          message: '该书写源需要网页登录：在浏览器打开下面地址登录后，'
              '把请求头（含 Cookie）粘贴回这里',
          openUrl: _absolute(loginUrl, source.bookSourceUrl),
          cookieMask: _cookieMask(source),
        );
    }
  }

  /// 执行 `loginUi` 里的自定义按钮动作。
  Future<LoginResultView> runAction(
    int sourceId,
    String action,
    Map<String, String> form,
  ) async {
    final source = _fetch.requireSource(sourceId);
    final script = _scriptOf(action.trim());
    if (script.isEmpty) {
      return LoginResultView(
        ok: false,
        loggedIn: _hasCookie(source),
        message: '按钮动作不是可执行的脚本',
        cookieMask: _cookieMask(source),
      );
    }
    return _runScript(source, script, form);
  }

  /// 保存手动粘贴的请求头；传空串表示清除。
  ///
  /// 解析出的 `Cookie:` 行会导入 CookieStore（其余头由抓取链路叠加），
  /// 这样「粘贴一次」就能同时解决鉴权与防盗链/UA 需求。
  Future<LoginResultView> saveHeader(int sourceId, String header) async {
    final source = _fetch.requireSource(sourceId);
    final url = source.bookSourceUrl;
    final text = header.trim();
    if (text.isEmpty) {
      _daos.sourceLogin.delete(url);
      return LoginResultView(
        ok: true,
        loggedIn: _hasCookie(source),
        message: '已清除粘贴的请求头',
        cookieMask: _cookieMask(source),
      );
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw LegadoException(ErrorCode.invalid, '书源地址非法: $url');
    }
    final cookieValue = _extractCookie(text);
    if (cookieValue.isNotEmpty) {
      try {
        _fetch.net.cookies.importCookieHeader(uri, cookieValue);
        await _fetch.persistCookies();
      } on Object catch (e) {
        _log.warning('导入 cookie 失败: $e');
      }
    }
    _daos.sourceLogin.put(
      SourceLoginRecord(
        bookSourceUrl: url,
        header: text,
        info: '手动粘贴请求头',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    final loggedIn = _hasCookie(source);
    return LoginResultView(
      ok: true,
      loggedIn: loggedIn,
      message: loggedIn
          ? '已保存请求头并导入 cookie'
          : '已保存请求头，但没有解析出 cookie（请确认包含 Cookie: 行）',
      cookieMask: _cookieMask(source),
    );
  }

  /// 清登录态。
  ///
  /// [withForm] = true 时连粘贴的请求头一起删；false 只清 cookie 与登录回执，
  /// 保留用户填过的请求头（便于换账号后只改 cookie）。
  Future<void> clear(int sourceId, bool withForm) async {
    final source = _fetch.requireSource(sourceId);
    final uri = Uri.tryParse(source.bookSourceUrl);
    if (uri != null) {
      _fetch.net.cookies.removeAll(uri);
      await _fetch.persistCookies();
    }
    if (withForm) {
      _daos.sourceLogin.delete(source.bookSourceUrl);
    } else {
      _daos.sourceLogin.clearInfo(source.bookSourceUrl);
    }
  }

  // ----------------------------------------------------------------------
  // 探测
  // ----------------------------------------------------------------------

  /// 探测当前账号是否需要登录。
  ///
  /// 判定顺序：有 `loginCheckJs` 就以脚本为准（返回 true = 需要登录，
  /// 与 Kotlin `checkLogin` 语义一致）；否则退化成「请求失败或没有 cookie」。
  Future<LoginProbeView> check(int sourceId, String probeUrl) async {
    final source = _fetch.requireSource(sourceId);
    final url = probeUrl.trim().isEmpty
        ? source.bookSourceUrl
        : _absolute(probeUrl.trim(), source.bookSourceUrl);

    HttpResponse response;
    try {
      response = await _fetch.requestUrl(source, url);
    } on Object catch (e) {
      return LoginProbeView(
        needLogin: true,
        detail: '请求失败: $e',
        statusCode: 0,
        url: url,
      );
    }

    final checkJs = _scriptOf((source.loginCheckJs ?? '').trim());
    if (checkJs.isNotEmpty) {
      final body = response.text();
      try {
        final context = SimpleRuleContext(
          js: _fetch.js,
          baseUrl: response.finalUri.toString(),
          source: source.toJson(),
          jsLib: source.jsLib ?? '',
          javaHost: _fetch.javaHostOf(source),
          extraBindings: <String, Object?>{
            'src': body,
            'result': body,
            'title': '',
          },
        );
        final value = await context.evalJs(checkJs, body);
        final needLogin = value == true || '$value'.trim().toLowerCase() == 'true';
        return LoginProbeView(
          needLogin: needLogin,
          detail: 'loginCheckJs 判定：$value',
          statusCode: response.statusCode,
          url: url,
        );
      } on Object catch (e) {
        return LoginProbeView(
          needLogin: !_hasCookie(source),
          detail: 'loginCheckJs 执行失败（$e），按 cookie 是否存在判断',
          statusCode: response.statusCode,
          url: url,
        );
      }
    }

    final hasCookie = _hasCookie(source);
    final needLogin = !response.isSuccess || !hasCookie;
    return LoginProbeView(
      needLogin: needLogin,
      detail: response.isSuccess
          ? (hasCookie ? 'HTTP ${response.statusCode}，已有 cookie' : 'HTTP ${response.statusCode}，但没有登录 cookie')
          : 'HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      url: url,
    );
  }

  // ----------------------------------------------------------------------
  // 内部
  // ----------------------------------------------------------------------

  /// 登录方式判定。
  ///
  /// 顺序很重要：`<js>` 也算「非空 loginUrl」，先判脚本再判 URL 形态，
  /// 否则带 js 的书源会被误当成网页登录。
  String _kindOf(String loginUrl) {
    final trimmed = loginUrl.trim();
    if (trimmed.isEmpty) return 'header';
    if (trimmed.contains('<js>') ||
        trimmed.toLowerCase().startsWith('@js:')) {
      return 'js';
    }
    // `地址,{"method":"POST",...}`：URL 规则里带选项，说明是接口登录。
    if (RegExp(r',\s*\{').hasMatch(trimmed)) return 'request';
    return 'page';
  }

  /// 从 `loginUrl` 里抠出可执行脚本。
  String _scriptOf(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return '';
    final jsBlock = RegExp(r'<js>([\s\S]*?)</js>', caseSensitive: false)
        .firstMatch(text);
    if (jsBlock != null) return jsBlock.group(1)?.trim() ?? '';
    if (text.toLowerCase().startsWith('@js:')) {
      return text.substring(4).trim();
    }
    return text;
  }

  /// 执行登录脚本。
  ///
  /// 表单字段同时以「变量」和「常见别名」注入：书源脚本里
  /// `{{key}}` / `{{password}}` / `username` 三种写法都能见到，
  /// 只注入 form 会让大部分现成书源直接 ReferenceError。
  Future<LoginResultView> _runScript(
    BookSource source,
    String script,
    Map<String, String> form,
  ) async {
    if (script.isEmpty) {
      return LoginResultView(
        ok: false,
        loggedIn: _hasCookie(source),
        message: '登录规则里没有可执行的脚本',
        cookieMask: _cookieMask(source),
      );
    }
    final aliases = <String, Object?>{...form};
    aliases.putIfAbsent('form', () => form);
    for (final entry in form.entries) {
      final lower = entry.key.toLowerCase();
      if (lower.contains('账') || lower.contains('user') || lower.contains('mail')) {
        aliases.putIfAbsent('key', () => entry.value);
        aliases.putIfAbsent('username', () => entry.value);
      } else if (lower.contains('密') || lower.contains('pass') || lower.contains('pwd')) {
        aliases.putIfAbsent('password', () => entry.value);
      }
    }
    // 部分书源脚本调 `login()` 走内建登录；我们没法可靠推断登录接口，
    // 给一个明确报错，比静默失败后让用户以为「点了没反应」好。
    aliases['login'] = (List<Object?> args) {
      throw StateError('该登录脚本调用 login()，需要网页登录，请改用 page 方式或粘贴请求头');
    };

    final context = SimpleRuleContext(
      js: _fetch.js,
      baseUrl: source.bookSourceUrl,
      variables: form,
      source: source.toJson(),
      jsLib: source.jsLib ?? '',
      javaHost: _fetch.javaHostOf(source, variables: form),
      extraBindings: aliases,
    );

    try {
      final value = await context.evalJs(script, null);
      await _fetch.persistCookies();
      final loggedIn = _hasCookie(source);
      final output = value == null ? '' : '$value';
      _daos.sourceLogin.put(
        SourceLoginRecord(
          bookSourceUrl: source.bookSourceUrl,
          header: _daos.sourceLogin.get(source.bookSourceUrl)?.header ?? '',
          info: loggedIn ? '脚本登录成功' : '脚本已执行，未检测到 cookie',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return LoginResultView(
        ok: true,
        loggedIn: loggedIn,
        message: loggedIn
            ? '登录成功'
            : '脚本执行完成，但没有新的登录 cookie（站点可能返回了失败页）',
        output: output,
        cookieMask: _cookieMask(source),
      );
    } on Object catch (e) {
      return LoginResultView(
        ok: false,
        loggedIn: _hasCookie(source),
        message: '登录脚本执行失败: $e',
        cookieMask: _cookieMask(source),
      );
    }
  }

  /// URL 规则形态的接口登录。
  Future<LoginResultView> _loginByRequest(
    BookSource source,
    String loginUrl,
    Map<String, String> form,
  ) async {
    try {
      final context = SimpleRuleContext(
        js: _fetch.js,
        baseUrl: source.bookSourceUrl,
        variables: form,
        source: source.toJson(),
        jsLib: source.jsLib ?? '',
        javaHost: _fetch.javaHostOf(source, variables: form),
      );
      final analyzer = UrlRuleAnalyzer(context);
      final analyzed = await analyzer.analyze(
        loginUrl,
        baseUrl: source.bookSourceUrl,
      );
      final response = await _fetch.requestAnalyzed(source, analyzed);
      await _fetch.persistCookies();
      final loggedIn = _hasCookie(source);
      final ok = response.isSuccess && loggedIn;
      _daos.sourceLogin.put(
        SourceLoginRecord(
          bookSourceUrl: source.bookSourceUrl,
          header: _daos.sourceLogin.get(source.bookSourceUrl)?.header ?? '',
          info: ok ? '接口登录成功' : '接口登录返回 HTTP ${response.statusCode}',
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return LoginResultView(
        ok: response.isSuccess,
        loggedIn: loggedIn,
        message: ok
            ? '登录成功'
            : 'HTTP ${response.statusCode}，${loggedIn ? '已拿到登录 cookie' : '没有拿到登录 cookie'}',
        cookieMask: _cookieMask(source),
      );
    } on Object catch (e) {
      return LoginResultView(
        ok: false,
        loggedIn: _hasCookie(source),
        message: '登录请求失败: $e',
        cookieMask: _cookieMask(source),
      );
    }
  }

  /// 从粘贴文本里取 Cookie 值。
  ///
  /// 支持三种形态（浏览器「复制为 cURL」与 DevTools 里都能见到）：
  /// - 多行请求头里的一行 `Cookie: a=1; b=2`
  /// - `cookie: a=1; b=2`（大小写不敏感）
  /// - 只有一行裸 cookie 串 `a=1; b=2`
  String _extractCookie(String text) {
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf(':');
      if (idx > 0 && trimmed.substring(0, idx).trim().toLowerCase() == 'cookie') {
        return trimmed.substring(idx + 1).trim();
      }
    }
    // 没有 `Cookie:` 行时，把「整段没有冒号、但含 =」的文本当裸 cookie 串。
    final single = text.trim();
    if (!single.contains('\n') && !single.contains(':') && single.contains('=')) {
      return single;
    }
    return '';
  }

  bool _hasCookie(BookSource source) {
    final uri = Uri.tryParse(source.bookSourceUrl);
    if (uri == null) return false;
    return _fetch.net.cookies.cookiesFor(uri).isNotEmpty;
  }

  /// 只暴露 cookie 名，值一律打码：面板可能在截图/日志里出现。
  String _cookieMask(BookSource source) {
    final uri = Uri.tryParse(source.bookSourceUrl);
    if (uri == null) return '';
    final cookies = _fetch.net.cookies.cookiesFor(uri);
    if (cookies.isEmpty) return '';
    final names = cookies.map((c) => '${c.name}=***').join('; ');
    return names.length > 160 ? '${names.substring(0, 157)}...' : names;
  }

  List<LoginFieldView> _fieldsOf(String? loginUi) {
    final raw = (loginUi ?? '').trim();
    if (raw.isEmpty) return const [];
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! Map) return const [];
    final chars = decoded['chars'];
    if (chars is! List) return const [];
    return [
      for (final item in chars)
        if (item is Map)
          LoginFieldView(
            name: '${item['name'] ?? ''}',
            type: '${item['type'] ?? 'text'}',
            action: '${item['action'] ?? ''}',
          ),
    ];
  }

  String _absolute(String url, String base) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.hasScheme) return url;
    final baseUri = Uri.tryParse(base);
    if (baseUri == null) return url;
    return baseUri.resolve(url).toString();
  }
}
