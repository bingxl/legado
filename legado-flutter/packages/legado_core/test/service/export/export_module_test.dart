import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:legado_core/src/core.dart';
import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/export/export_module.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/source/source_fetch_module.dart';
import 'package:legado_core/src/service/source/source_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 书架导出链路测试：书源 → 目录 → 正文（含图片）→ EPUB3 包。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late SourceModule source;
  late SourceFetchModule fetch;
  late ReaderModule reader;
  late ExportModule export;
  late Registry registry;
  late HttpServer server;
  late String base;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-export');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    source = SourceModule();
    source.register(registry, ctx());
    fetch = SourceFetchModule();
    fetch.register(registry, ctx());
    reader = ReaderModule();
    reader.register(registry, ctx());
    export = ExportModule();
    export.register(registry, ctx());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final response = request.response;
      final path = request.uri.path;
      if (path == '/cover.jpg' || path == '/img/1.png') {
        response.headers.contentType = ContentType('image', 'png');
        response.add(<int>[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
        await response.close();
        return;
      }
      response.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
      final body = switch (path) {
        '/info' =>
          '<h1 class="name">导出测试书</h1><span>作者甲</span>'
          '<img class="cover" src="/cover.jpg">'
          '<a class="toc" href="/toc">目录</a>',
        '/toc' => '''<ul>
<li><a href="/ch/1">第一章 起</a></li>
<li><a href="/ch/2">第二章 承</a></li></ul>''',
        '/ch/1' => '<div id="content">正文一<img src="/img/1.png"></div>',
        '/ch/2' => '<div id="content">正文二<script>bad()</script></div>',
        _ => '<html></html>',
      };
      response.write(body);
      await response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await export.close();
    await reader.close();
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

  Future<int> addSourceAndBook() async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '导出源',
      'bookSourceGroup': '测试',
      'enabled': true,
      'ruleBookInfo': jsonEncode({
        'name': 'h1.name@text',
        'author': 'span@text',
        'coverUrl': 'img.cover@src',
        'tocUrl': '.toc@href',
      }),
      'ruleToc': jsonEncode({
        'chapterList': 'li',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      }),
      'ruleContent': jsonEncode({'content': '#content@html'}),
    });
    final saved = await callMap('Source.Save', [
      0,
      '导出源',
      '测试',
      base,
      '',
      raw,
      true,
      0,
    ]);
    final sourceId = saved['id'] as int;
    final preview = await callMap('Source.PreviewBook', [
      sourceId,
      '$base/info',
      '',
      '',
      '{}',
    ]);
    expect(preview['error'], isNull);
    final added = await callMap('Source.AddToShelf', [
      sourceId,
      '$base/info',
      '${preview['name']}',
      '${preview['author']}',
      '{}',
      0,
    ]);
    expect(added['error'], isNull);
    return (await call('Shelf.ListBooks', [0]) as List).first['id'] as int;
  }

  test('依赖与两个方法已注册', () {
    expect(export.name, 'export');
    expect(export.dependsOn, containsAll(<String>['store', 'reader']));
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>['Export.Formats', 'Export.Book']),
    );
  });

  test('Formats 列出 EPUB 已实现、其他格式接口预留', () async {
    final formats = await call('Export.Formats') as List;
    expect(formats.length, greaterThanOrEqualTo(4));
    final byId = {
      for (final f in formats.cast<Map<String, Object?>>())
        '${f['id']}': f['implemented'],
    };
    expect(byId['epub'], isTrue);
    expect(byId['txt'], isFalse);
    expect(byId['pdf'], isFalse);
    expect(byId['mobi'], isFalse);
  });

  test('非 EPUB 格式返回 NOT_IMPLEMENTED 而不是静默空文件', () async {
    final id = await addSourceAndBook();
    for (final format in ['txt', 'pdf', 'mobi']) {
      try {
        await call('Export.Book', [id, format, home.path]);
        fail('格式 $format 应当抛 NOT_IMPLEMENTED');
      } on LegadoException catch (e) {
        expect(e.code, ErrorCode.notImplemented);
      }
    }
  });

  test('导出 EPUB：zip 结构、正文、图片内嵌、目录齐备', () async {
    final id = await addSourceAndBook();
    final result = await callMap('Export.Book', [id, '', '']);
    expect(result['format'], 'epub');
    expect(result['chapters'], 2);

    final file = File('${result['path']}');
    expect(file.existsSync(), isTrue);
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

    // mimetype 必须是第一个条目且不压缩。
    expect(archive.files.first.name, 'mimetype');
    expect(archive.files.first.compression, CompressionType.none);
    expect(utf8.decode(archive.files.first.content as List<int>),
        'application/epub+zip');

    final names = archive.files.map((f) => f.name).toList();
    expect(names, contains('META-INF/container.xml'));
    expect(names, contains('OEBPS/content.opf'));
    expect(names, contains('OEBPS/nav.xhtml'));
    expect(names, contains('OEBPS/toc.ncx'));
    expect(names, contains('OEBPS/cover.xhtml'));
    expect(names.where((n) => n.startsWith('OEBPS/images/')).length,
        greaterThanOrEqualTo(2)); // 封面 + 正文图片

    String content(String name) =>
        utf8.decode(archive.files.firstWhere((f) => f.name == name).content as List<int>);

    final opf = content('OEBPS/content.opf');
    expect(opf, contains('version="3.0"'));
    expect(opf, contains('导出测试书'));
    expect(opf, contains('properties="cover-image"'));
    expect(opf, contains('ch0'));
    expect(opf, contains('ch1'));

    final chapter1 = content('OEBPS/text/chapter_0000.xhtml');
    expect(chapter1, contains('正文一'));
    expect(chapter1, contains('../images/img_'));
    final chapter2 = content('OEBPS/text/chapter_0001.xhtml');
    expect(chapter2, contains('正文二'));
    // 网页脚本不应被带进离线 EPUB。
    expect(chapter2, isNot(contains('bad()')));
    expect(chapter2, isNot(contains('<script')));

    final nav = content('OEBPS/nav.xhtml');
    expect(nav, contains('第一章 起'));
    expect(nav, contains('第二章 承'));
  });

  test('未知书 ID 返回 NOT_FOUND', () async {
    try {
      await call('Export.Book', [99999, 'epub', '']);
      fail('应当抛 NOT_FOUND');
    } on LegadoException catch (e) {
      expect(e.code, ErrorCode.notFound);
    }
  });
}
