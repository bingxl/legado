import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/login/login_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/source/source_fetch_module.dart';
import 'package:legado_core/src/service/source/source_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// `SourceLogin.*` 七个方法的端到端测试。
///
/// 用真实 HttpServer：cookie 是网络层写的，mock 掉就等于没测登录。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late SourceModule source;
  late SourceFetchModule fetch;
  late LoginModule login;
  late Registry registry;
  late HttpServer server;
  late String base;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-login');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    source = SourceModule();
    source.register(registry, ctx());
    fetch = SourceFetchModule();
    fetch.register(registry, ctx());
    login = LoginModule();
    login.register(registry, ctx());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final response = request.response;
      final path = request.uri.path;
      if (path == '/login') {
        response.headers.add('set-cookie', 'sid=abc123; Path=/');
        response.write('ok');
      } else if (path == '/probe') {
        response.write('请登录');
      } else {
        response.write('home');
      }
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await login.close();
    await fetch.close();
    await source.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  Future<int> addSource({
    required String url,
    String? loginUrl,
    String? loginUi,
    String? loginCheckJs,
    String jsLib = '',
  }) async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': url,
      'bookSourceName': '登录源',
      'bookSourceGroup': '测试',
      'enabled': true,
      'searchUrl': '$url/search?q={{key}}',
      if (loginUrl != null) 'loginUrl': loginUrl,
      if (loginUi != null) 'loginUi': loginUi,
      if (loginCheckJs != null) 'loginCheckJs': loginCheckJs,
      if (jsLib.isNotEmpty) 'jsLib': jsLib,
      'ruleSearch': jsonEncode(<String, Object?>{
        'bookList': 'li',
        'name': 'a@text',
        'bookUrl': 'a@href',
      }),
    });
    final saved = await callMap('Source.Save', [
      0,
      '登录源',
      '测试',
      url,
      '',
      raw,
      true,
      0,
    ]);
    return saved['id'] as int;
  }

  test('Profile 按 loginUrl 形态判定登录方式', () async {
    final jsId = await addSource(url: '$base/s1', loginUrl: '<js>1</js>');
    final reqId = await addSource(
      url: '$base/s2',
      loginUrl: '$base/login,{"method":"POST","body":"u=1"}',
    );
    final pageId = await addSource(url: '$base/s3', loginUrl: '$base/login');
    final headerId = await addSource(url: '$base/s4');

    expect((await callMap('SourceLogin.Profile', [jsId]))['kind'], 'js');
    expect((await callMap('SourceLogin.Profile', [reqId]))['kind'], 'request');
    expect((await callMap('SourceLogin.Profile', [pageId]))['kind'], 'page');
    expect((await callMap('SourceLogin.Profile', [headerId]))['kind'], 'header');
  });

  test('Profile 解析 loginUi 字段并回报 cookie 状态', () async {
    final id = await addSource(
      url: '$base/s5',
      loginUrl: '<js>1</js>',
      loginUi: jsonEncode(<String, Object?>{
        'chars': [
          {'name': '账号', 'type': 'text'},
          {'name': '密码', 'type': 'password'},
          {'name': '登录', 'type': 'button', 'action': '@js:1'},
        ],
      }),
      loginCheckJs: '@js:result.indexOf("请登录") >= 0',
    );
    final profile = await callMap('SourceLogin.Profile', [id]);
    expect((profile['fields'] as List), hasLength(3));
    expect(profile['hasCookie'], false);
    expect(profile['kind'], 'js');
    expect('${profile['checkJs']}', contains('请登录'));
  });

  test('js 脚本登录：Set-Cookie 收下并落盘', () async {
    final id = await addSource(
      url: '$base/s6',
      loginUrl: '<js>java.ajax("$base/login")</js>',
    );
    final result = await callMap('SourceLogin.Login', [
      id,
      {'账号': 'u', '密码': 'p'},
    ]);
    expect(result['ok'], true);
    expect(result['loggedIn'], true);
    expect('${result['cookieMask']}', contains('sid=***'));

    final profile = await callMap('SourceLogin.Profile', [id]);
    expect(profile['hasCookie'], true);

    // 登录态必须能跨进程：cookies.json 落盘是唯一途径。
    final cookieFile = File('${home.path}/cookies.json');
    expect(cookieFile.existsSync(), true);
    expect(cookieFile.readAsStringSync(), contains('abc123'));
  });

  test('URL 规则（request）登录', () async {
    final id = await addSource(
      url: '$base/s7',
      loginUrl: '$base/login,{"method":"POST","body":"u={{账号}}"}',
    );
    final result = await callMap('SourceLogin.Login', [
      id,
      {'账号': 'u'},
    ]);
    expect(result['ok'], true);
    expect(result['loggedIn'], true);
  });

  test('page 方式返回 openUrl，不假装登录成功', () async {
    final id = await addSource(url: '$base/s8', loginUrl: '$base/login');
    final result = await callMap('SourceLogin.Login', [id, const {}]);
    expect('${result['openUrl']}', '$base/login');
    expect(result['loggedIn'], false);
    expect('${result['message']}', contains('网页登录'));
  });

  test('粘贴请求头：提取 Cookie 并保留原文', () async {
    final id = await addSource(url: '$base/s9');
    final header = 'Cookie: uid=42; token=zzz\nUser-Agent: Mozilla/5.0';
    final result = await callMap('SourceLogin.SaveHeader', [id, header]);
    expect(result['ok'], true);
    expect(result['loggedIn'], true);

    expect(await call('SourceLogin.Header', [id]), header);

    final profile = await callMap('SourceLogin.Profile', [id]);
    expect(profile['hasCookie'], true);
    expect('${profile['header']}', contains('User-Agent'));
  });

  test('Clear(withForm=false) 只清 cookie，保留请求头', () async {
    final id = await addSource(url: '$base/s10');
    await call('SourceLogin.SaveHeader', [id, 'Cookie: uid=1']);
    await call('SourceLogin.Clear', [id, false]);

    final profile = await callMap('SourceLogin.Profile', [id]);
    expect(profile['hasCookie'], false);
    expect('${profile['header']}', contains('uid=1'));
  });

  test('Clear(withForm=true) 连请求头一起清', () async {
    final id = await addSource(url: '$base/s11');
    await call('SourceLogin.SaveHeader', [id, 'Cookie: uid=1']);
    await call('SourceLogin.Clear', [id, true]);

    final profile = await callMap('SourceLogin.Profile', [id]);
    expect(profile['hasCookie'], false);
    expect('${profile['header']}', isEmpty);
  });

  test('Check 用 loginCheckJs 判定需要登录', () async {
    final id = await addSource(
      url: '$base/s12',
      loginCheckJs: 'result.indexOf("请登录") >= 0',
    );
    final probe = await callMap('SourceLogin.Check', [id, '$base/probe']);
    expect(probe['needLogin'], true);
    expect(probe['statusCode'], 200);
    expect('${probe['detail']}', contains('loginCheckJs'));
  });

  test('Check 无脚本时按 cookie 与 HTTP 状态判断', () async {
    final id = await addSource(url: '$base/s13');
    final probe = await callMap('SourceLogin.Check', [id, '$base/probe']);
    expect(probe['needLogin'], true);
    expect('${probe['detail']}', contains('没有登录 cookie'));
  });
}
