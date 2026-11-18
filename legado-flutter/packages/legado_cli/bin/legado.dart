import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:legado_core/legado_core.dart';
import 'package:path/path.dart' as p;

/// legado 的 CLI 宿主。
///
/// 存在的意义不是「做一个终端工具」，而是给内核一个不依赖 Flutter 的验证面：
/// 任何业务逻辑都必须能在 `dart run legado_cli:legado call ...` 下跑通，
/// 否则它就不是「非 UI 逻辑」，只是「还没搬出去的 UI 逻辑」。
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption(
      'home',
      help: '数据目录（默认取 LEGADO_HOME，否则 ~/.legado）',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

  parser.addCommand('info').addFlag('json', negatable: false);
  parser.addCommand('methods').addOption(
    'domain',
    abbr: 'd',
    help: '只列出某个域，如 Shelf',
  );
  parser.addCommand('call').addFlag('json', negatable: false);
  parser.addCommand('serve').addOption(
    'port',
    abbr: 'p',
    defaultsTo: '0',
    help: '0 表示随机端口',
  );

  final ArgResults root;
  try {
    root = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    stderr.writeln(_usage(parser));
    exit(64);
  }

  if (root['help'] as bool || root.command == null) {
    stdout.writeln(_usage(parser));
    exit(root.command == null && !(root['help'] as bool) ? 64 : 0);
  }

  final home = _resolveHome(root['home'] as String?);
  try {
    Directory(home).createSync(recursive: true);
  } on FileSystemException catch (e) {
    // 最常见的两个原因都跟权限有关，直接给出可操作的提示，
    // 否则用户只会看到一句 errno = 5。
    stderr.writeln('无法创建数据目录: $home');
    stderr.writeln('  ${e.osError?.message ?? e.message}');
    stderr.writeln('  可换一个目录: legado --home <dir> ...，或设置 LEGADO_HOME');
    exit(1);
  }

  final core = LegadoCore.instance;
  await core.init(homeDir: home, version: _version(), host: 'cli');

  try {
    switch (root.command!.name) {
      case 'info':
        _print(await core.call('System.Info'), pretty: !root.command!['json']);
      case 'methods':
        final domain = root.command!['domain'] as String?;
        final list = core.methods(domain);
        if (list.isEmpty) {
          stderr.writeln('没有匹配的方法${domain == null ? '' : '（域: $domain）'}');
          exit(1);
        }
        for (final m in list) {
          final sig = m.params.isEmpty ? '' : '(${m.params.join(', ')})';
          stdout.writeln('${m.name}$sig${m.doc.isEmpty ? '' : '  // ${m.doc}'}');
        }
      case 'call':
        final rest = root.command!.rest;
        if (rest.isEmpty) {
          stderr.writeln('用法: legado call <Domain.Verb> [argsJSON]');
          exit(64);
        }
        final method = rest.first;
        final argsRaw = rest.length > 1 ? rest[1] : '[]';
        final envelope = jsonEncode({
          'id': 1,
          'method': method,
          'args': jsonDecode(argsRaw),
        });
        final raw = await core.handle(envelope);
        _print(jsonDecode(raw), pretty: true);
        final map = jsonDecode(raw) as Map<String, dynamic>;
        if (map['ok'] != true) exit(1);
      case 'serve':
        await _serve(core, int.tryParse(root.command!['port'] as String) ?? 0);
      case final other:
        stderr.writeln('未知命令: $other');
        stderr.writeln(_usage(parser));
        exit(64);
    }
  } on LegadoException catch (e) {
    stderr.writeln('${e.code}: ${e.message}');
    exit(1);
  } finally {
    if (root.command?.name != 'serve') {
      await core.close();
    }
  }
}

/// 数据目录：显式参数 > 环境变量 > 用户目录下的隐藏目录。
///
/// 与旧 Go 版保持一致（LEGADO_HOME 优先），这样升级后不用重新导入书源。
String _resolveHome(String? cli) {
  if (cli != null && cli.isNotEmpty) return p.absolute(cli);
  final env = Platform.environment['LEGADO_HOME'];
  if (env != null && env.isNotEmpty) return p.absolute(env);
  final userHome =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  return p.join(userHome, '.legado');
}

String _version() {
  final env = Platform.environment['LEGADO_VERSION'];
  return (env == null || env.isEmpty) ? 'dev' : env;
}

void _print(Object? value, {bool pretty = false}) {
  stdout.writeln(
    pretty
        ? const JsonEncoder.withIndent('  ').convert(value)
        : jsonEncode(value),
  );
}

String _usage(ArgParser parser) =>
    '''
legado —— 纯 Dart 内核的命令行宿主

用法: legado [--home <dir>] <command> [参数]

${parser.usage}''';

/// 最小 HTTP 数据面。
///
/// 只做三件事：健康检查、方法表、RPC。正文/图片这类大流量资源在 M3 之后再加，
/// 现在没有业务数据，加了也是空壳。
Future<void> _serve(LegadoCore core, int port) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('listening http://127.0.0.1:${server.port}');

  await for (final req in server) {
    try {
      if (req.uri.path == '/healthz') {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'ok': true, 'version': _version()}));
      } else if (req.uri.path == '/methods') {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(core.methods().map((m) => m.describe()).toList()));
      } else if (req.uri.path == '/rpc') {
        if (req.method != 'POST') {
          req.response.statusCode = 405;
        } else {
          final body = await utf8.decoder.bind(req).join();
          req.response
            ..headers.contentType = ContentType.json
            ..write(await core.handle(body));
        }
      } else {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({'err': 'no such route'}));
      }
    } catch (e) {
      req.response.statusCode = 500;
      req.response.write(jsonEncode({'err': '$e'}));
    } finally {
      await req.response.close();
    }
  }
}
