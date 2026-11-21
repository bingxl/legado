import 'dart:convert';

import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../service_args.dart';
import '../source/source_fetch_module.dart';
import 'login_service.dart';

/// 书源登录域：7 个 `SourceLogin.*` 方法。
///
/// 依赖 `sourcefetch` 而不是自己建网络层：登录态必须和抓取共用同一个
/// CookieStore，否则会出现「登录成功但正文仍要登录」的灵异现象。
class LoginModule extends CoreModule {
  @override
  String get name => 'login';

  @override
  List<String> get dependsOn => const ['store', 'sourcefetch'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) throw StateError('登录域依赖 store');
    final fetchModule = SourceFetchModule.instance;
    if (fetchModule == null) throw StateError('登录域依赖 sourcefetch');
    final service = LoginService(
      daos: store.daos,
      fetch: fetchModule.service,
    );

    registry.method(
      'SourceLogin.Profile',
      (args) async => service.profile(asInt(arg(args, 0))).toJson(),
      params: const ['sourceID int'],
      doc: '登录面板全部信息；登录方式 kind ∈ js/request/page/header',
    );

    registry.method(
      'SourceLogin.Login',
      (args) async => (await service.login(
        asInt(arg(args, 0)),
        asStringMap(arg(args, 1)),
      ))
          .toJson(),
      params: const ['sourceID int', 'form map<string,string>'],
      doc: '按 loginUrl 形态分派：js 脚本 / URL 规则请求 / 网页登录（返回 openUrl）',
    );

    registry.method(
      'SourceLogin.RunAction',
      (args) async => (await service.runAction(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
        asStringMap(arg(args, 2)),
      ))
          .toJson(),
      params: const ['sourceID int', 'action string', 'form map<string,string>'],
      doc: '执行 loginUi 里的自定义按钮脚本',
    );

    registry.method(
      'SourceLogin.SaveHeader',
      (args) async => (await service.saveHeader(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
      ))
          .toJson(),
      params: const ['sourceID int', 'header string'],
      doc: '保存手动粘贴的请求头；提取 Cookie 导入 CookieStore，空串=清除',
    );

    registry.method(
      'SourceLogin.Header',
      (args) async => service.header(asInt(arg(args, 0))),
      params: const ['sourceID int'],
      doc: '粘贴的请求头原文',
    );

    registry.method(
      'SourceLogin.Clear',
      (args) async {
        await service.clear(asInt(arg(args, 0)), asBool(arg(args, 1)));
        return null;
      },
      params: const ['sourceID int', 'withForm bool'],
      doc: 'withForm=true 连粘贴的请求头一起删；false 只清 cookie 与回执',
    );

    registry.method(
      'SourceLogin.Check',
      (args) async => (await service.check(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
      ))
          .toJson(),
      params: const ['sourceID int', 'probeURL string'],
      doc: 'needLogin 判定；probeURL 空时用书源地址',
    );
  }
}

/// 表单参数：UI 传 Map，CLI/事件里可能是 JSON 文本，两种都吃。
///
/// 不抛类型错：登录表单少字段是常态（有的书源只要账号），
/// 把「多传/少传」变成硬失败只会让登录面板莫名其妙报错。
Map<String, String> asStringMap(Object? raw) {
  if (raw == null) return const <String, String>{};
  if (raw is Map) {
    return <String, String>{
      for (final entry in raw.entries) '${entry.key}': '${entry.value}',
    };
  }
  if (raw is String) {
    final text = raw.trim();
    if (text.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return <String, String>{
          for (final entry in decoded.entries) '${entry.key}': '${entry.value}',
        };
      }
    } on FormatException {
      return const <String, String>{};
    }
  }
  return const <String, String>{};
}
