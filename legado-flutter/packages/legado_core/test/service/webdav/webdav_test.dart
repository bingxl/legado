import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/library/library_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/webdav/webdav_client.dart';
import 'package:legado_core/src/service/webdav/webdav_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// WebDAV 域接线测试：协议层（PROPFIND 解析 / GET / PUT / DELETE / MKCOL）
/// + 配置存取 + 11 个 kernel 方法 + 书籍导入落库。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late LibraryModule library;
  late WebDAVModule webdav;
  late Registry registry;
  late HttpServer server;
  late String base;

  // 模拟的 WebDAV 目录：工作根 /dav/legado/ 下有一个子目录和两个文件。
  final propfindXml = '''<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/legado/</d:href>
    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/legado/sub/</d:href>
    <d:propstat><d:prop>
      <d:displayname>sub</d:displayname>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
    </d:prop></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/legado/book%20one.txt</d:href>
    <d:propstat><d:prop>
      <d:displayname>book one.txt</d:displayname>
      <d:resourcetype/>
      <d:getcontentlength>1024</d:getcontentlength>
      <d:getlastmodified>Wed, 21 Oct 2015 07:28:00 GMT</d:getlastmodified>
      <d:getcontenttype>text/plain</d:getcontenttype>
    </d:prop></d:propstat>
  </d:response>
</d:multistatus>''';

  final uploads = <String, List<int>>{};
  final deleted = <String>[];

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-webdav');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    library = LibraryModule();
    library.register(registry, ctx());
    webdav = WebDAVModule();
    webdav.register(registry, ctx());

    uploads.clear();
    deleted.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}/dav/';
    server.listen((request) async {
      final method = request.method;
      final path = request.uri.path;
      // 先读完请求体（PUT 要消费掉，否则连接状态错乱）。
      final bodyBytes = await request.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk as List<int>),
      );
      if (method == 'PUT') {
        uploads[path] = bodyBytes;
      } else if (method == 'DELETE') {
        deleted.add(path);
      }
      request.response.statusCode = 200;
      if (method == 'PROPFIND') {
        request.response.headers.contentType = ContentType('application', 'xml');
        // 非工作根（如 sub/）返回空的 multistatus，避免递归扫描时重复计数。
        final isRoot = path.replaceAll(RegExp(r'/+$'), '') == '/dav/legado';
        request.response.add(utf8.encode(isRoot ? propfindXml : '<d:multistatus xmlns:d="DAV:"/>'));
      } else if (method == 'GET') {
        request.response.headers.contentType =
            ContentType('text', 'plain', charset: 'utf-8');
        request.response.add(utf8.encode('第一章\n这是正文内容……\n第二章\n更多内容。'));
      }
      await request.response.close();
    });

    // 配置 WebDAV 指向本地测试服务器。
    await call('WebDAV.SaveConfig', [base, 'user', 'pass', 'legado', true]);
  });

  tearDown(() async {
    await server.close(force: true);
    await webdav.close();
    await library.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('URL 规范化：dav/davs scheme 与尾斜杠', () {
    expect(WebDavClient.normalizeUrl('dav://x.com/dav'), 'http://x.com/dav/');
    expect(WebDavClient.normalizeUrl('davs://x.com/dav/'), 'https://x.com/dav/');
    expect(WebDavClient.normalizeUrl('example.com'), 'https://example.com/');
  });

  test('配置：密码脱敏 + password 为空保持不变', () async {
    final cfg = await callMap('WebDAV.GetConfig');
    expect(cfg['url'], base);
    expect(cfg['username'], 'user');
    expect(cfg['hasPassword'], isTrue);
    expect(cfg.containsKey('password'), isFalse);
    expect(cfg['rootPath'], 'legado');
    expect(cfg['autoSync'], isTrue);
    expect(cfg['configured'], isTrue);

    // 空密码保持原值。
    await call('WebDAV.SaveConfig', [base, 'user2', '', 'legado', false]);
    final cfg2 = await callMap('WebDAV.GetConfig');
    expect(cfg2['username'], 'user2');
    expect(cfg2['hasPassword'], isTrue); // 原密码仍在
    expect(cfg2['autoSync'], isFalse);
  });

  test('Test 列根目录成功；List 解析 PROPFIND 的相对路径与目录标记', () async {
    await expectLater(call('WebDAV.Test'), completes);
    final entries = await callList('WebDAV.List', ['']);
    expect(entries.length, 2);
    final sub = entries.firstWhere((e) => e['name'] == 'sub');
    expect(sub['isDir'], isTrue);
    expect(sub['path'], 'sub/');
    final book = entries.firstWhere((e) => e['name'] == 'book one.txt');
    expect(book['isDir'], isFalse);
    expect(book['path'], 'book one.txt');
    expect(book['size'], 1024);
    // Wed, 21 Oct 2015 07:28:00 GMT 的正确 UTC epoch。
    expect(book['modTime'], DateTime.utc(2015, 10, 21, 7, 28).millisecondsSinceEpoch);
  });

  test('ScanBooks 递归返回书籍文件（含格式）', () async {
    final books = await callList('WebDAV.ScanBooks', ['']);
    expect(books.length, 1);
    expect(books.single['name'], 'book one.txt');
    expect(books.single['format'], 'TXT');
  });

  test('协议层 PUT / DELETE / MKCOL', () async {
    final conn = WebDavConnection(url: base, username: 'u', password: 'p', rootPath: 'legado');
    final client = WebDavClient(conn);
    await client.upload('a/b.txt', utf8.encode('hello'));
    expect(uploads['/dav/legado/a/b.txt'], utf8.encode('hello'));
    await client.delete('a/b.txt');
    expect(deleted, contains('/dav/legado/a/b.txt'));
    await expectLater(client.makeDir('newdir'), completes);
  });

  test('未配置时抛 SOURCE_EMPTY', () async {
    await call('WebDAV.SaveConfig', ['', '', '', '', false]);
    await expectLater(
      call('WebDAV.Test'),
      throwsA(isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.sourceEmpty)),
    );
  });

  test('StartBookImport 下载并导入书籍到书架，ImportStatus 回执完成', () async {
    final job = await callMap('WebDAV.StartBookImport', [
      ['book one.txt'],
      0,
    ]);
    expect(job['state'], 'running');
    // 等待后台任务完成（轮询状态，不用固定 sleep）。
    Map<String, Object?> status = job;
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      status = await callMap('WebDAV.ImportStatus');
      if (status['state'] != 'running') break;
    }
    expect(status['state'], 'done');
    expect((status['imported'] as List).length, 1);

    // 书确实进了书架（文件名 book one.txt → 书名 book one）。
    final shelfBooks = await callList('Shelf.ListBooks', [0]);
    expect(shelfBooks.any((b) => (b['name'] as String).contains('book one')), isTrue,
        reason: 'shelf books: ${shelfBooks.map((b) => b['name']).toList()}');
  });
}
