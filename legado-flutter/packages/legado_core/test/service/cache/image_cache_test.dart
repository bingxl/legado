import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/cache/cache_module.dart';
import 'package:legado_core/src/service/cache/image_cache_service.dart';
import 'package:legado_core/src/service/library/library_module.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
import 'package:legado_core/src/service/setting/settings_module.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/source/source_fetch_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 图片章缓存：正文之外还要把图片二进制落盘，否则离线只能看到失效地址。
/// 对齐原版 `CacheBook.download()` + `BookHelp.saveImages()`。
void main() {
  group('ImageCacheService', () {
    late Directory home;
    late HttpServer server;
    late String base;
    late ImageCacheService cache;
    final hits = <String, int>{};

    setUp(() async {
      home = await Directory.systemTemp.createTemp('legado-image-cache');
      hits.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        if (path == '/bad.png') {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.parse('image/png');
        request.response.writeAll(<Object>[
          for (var i = 0; i < 128; i++) 'img:$path:',
        ]);
        await request.response.close();
      });
      cache = ImageCacheService(homeDir: home.path);
    });

    tearDown(() async {
      cache.close();
      await server.close(force: true);
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('缓存键稳定、扩展名按 URL 后缀，未知后缀回落 jpg', () {
      final key = ImageCacheService.imageKey('$base/a.png');
      expect(key, hasLength(16));
      expect(ImageCacheService.imageKey('$base/a.png'), key);
      expect(ImageCacheService.imageKey('$base/b.png') == key, isFalse);
      expect(ImageCacheService.imageExtension('$base/a.webp'), 'webp');
      expect(ImageCacheService.imageExtension('$base/a'), 'jpg');
    });

    test('图片下载落盘；重复缓存跳过已存在文件；单张失败不影响整章', () async {
      final urls = <String>['$base/1.png', '$base/2.png', '$base/bad.png'];
      final bytes = await cache.downloadChapter(7, 3, urls);
      expect(bytes, greaterThan(0));
      expect(hits['/1.png'], 1);
      expect(hits['/2.png'], 1);
      expect(hits['/bad.png'], 1);

      final paths = cache.cachedPaths(7, 3, urls);
      expect(paths, hasLength(2));
      expect(paths.values.every((p) => File(p).existsSync()), isTrue);
      expect(cache.hasAllImages(7, 3, urls), isFalse);
      expect(cache.hasAllImages(7, 3, urls.take(2)), isTrue);

      // 已存在的两张不再联网；失败的那张会重试。
      await cache.downloadChapter(7, 3, urls);
      expect(hits['/1.png'], 1);
      expect(hits['/2.png'], 1);
      expect(hits['/bad.png'], 2);
    });
  });

  group('Cache.Start 图片章', () {
    late Directory home;
    late HttpServer server;
    late String base;
    late StoreModule store;
    late ShelfModule shelf;
    late SourceFetchModule fetch;
    late ReaderModule reader;
    late SettingsModule settings;
    late LibraryModule library;
    late CacheModule cacheModule;
    late Registry registry;
    late int bookId;
    final hits = <String, int>{};

    LegadoContext ctx() =>
        LegadoContext(homeDir: home.path, version: 'test', host: 'test');

    setUp(() async {
      home = await Directory.systemTemp.createTemp('legado-chapter-images');
      hits.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        final path = request.uri.path;
        hits[path] = (hits[path] ?? 0) + 1;
        if (path.startsWith('/img/')) {
          request.response.headers.contentType = ContentType.parse('image/png');
          for (var i = 0; i < 64; i++) {
            request.response.write('$path-payload-');
          }
        } else {
          request.response.headers.contentType = ContentType.html;
          request.response.write(
            '<div id="content">'
            '<img src="/img/a.png"><img src="/img/b.png">'
            '</div>',
          );
        }
        await request.response.close();
      });

      store = StoreModule();
      await store.migrate(ctx());
      registry = Registry();
      shelf = ShelfModule();
      shelf.register(registry, ctx());
      settings = SettingsModule();
      settings.register(registry, ctx());
      fetch = SourceFetchModule();
      fetch.register(registry, ctx());
      reader = ReaderModule();
      reader.register(registry, ctx());
      library = LibraryModule();
      library.register(registry, ctx());
      cacheModule = CacheModule();
      cacheModule.register(registry, ctx());

      store.daos.bookSource.insert(
        BookSource(
          bookSourceUrl: base,
          bookSourceName: '漫画源',
          enabled: true,
          ruleContent: jsonEncode({'content': '#content@html'}),
        ),
      );
      store.daos.book.insert(
        Book(
          bookUrl: '$base/b/1',
          name: '漫画样例',
          author: '测试',
          origin: base,
          type: BookType.image,
          totalChapterNum: 1,
        ),
      );
      store.daos.chapter.insert(
        BookChapter(
          url: '$base/c/1',
          bookUrl: '$base/b/1',
          index: 0,
          title: '第1图',
        ),
      );
      bookId = store.daos.book.idOf('$base/b/1')!;
    });

    tearDown(() async {
      await cacheModule.close();
      await library.close();
      await reader.close();
      await fetch.close();
      await settings.close();
      await shelf.close();
      await store.close();
      await server.close(force: true);
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    Future<Map<String, Object?>> callMap(String method,
            [List<Object?> args = const []]) async =>
        (await registry.invoke(method, args) as Map).cast<String, Object?>();

    Future<Map<String, Object?>> waitJob() async {
      for (var i = 0; i < 300; i++) {
        final jobs = (await registry.invoke('Cache.Jobs', const []) as List)
            .cast<Map<String, Object?>>();
        if (jobs.isNotEmpty && jobs.first['state'] != 'running') {
          return jobs.first;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('缓存任务 3 秒内没有结束');
    }

    test('缓存整章时图片二进制落盘，Stats.size 含图片字节，GetContent 返回本地路径',
        () async {
      final job = await callMap('Cache.Start', [bookId, 'chapters', [0]]);
      expect(job['state'], anyOf('running', 'done'));
      final finished = await waitJob();
      expect(finished['state'], 'done');
      expect(finished['done'], 1);
      expect(finished['failed'], 0);

      // 两张图都真的下载了，不是只写了地址列表。
      final dir = Directory(p.join(home.path, 'cache', 'chapter', '$bookId', '0'));
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      expect(files.every((f) => f.lengthSync() > 0), isTrue);
      expect(hits['/img/a.png'], 1);
      expect(hits['/img/b.png'], 1);

      final stats = await callMap('Cache.Stats');
      final cached = store.daos.chapterCache.get('$base/b/1', 0)!;
      final textBytes =
          utf8.encode(cached.html).length + utf8.encode(cached.images).length;
      expect(stats['size'], greaterThan(textBytes));
      expect(stats['size'], textBytes + files.fold(0, (n, f) => n + f.lengthSync()));

      final content = await callMap('Reader.GetContent', [bookId, 0]);
      final images = (content['images'] as List).cast<String>();
      expect(images, hasLength(2));
      final paths = (content['imagePaths'] as Map).cast<String, String>();
      expect(paths, hasLength(2));
      expect(paths.values.every((p) => File(p).existsSync()), isTrue);

      // 命中缓存后不再联网抓正文/图片。
      expect(hits['/c/1'], 1);
      await callMap('Reader.GetContent', [bookId, 0]);
      expect(hits['/c/1'], 1);
      expect(hits['/img/a.png'], 1);
    });

    test('PurgeBook 连磁盘图片一起清掉', () async {
      await callMap('Cache.Start', [bookId, 'chapters', [0]]);
      await waitJob();
      final dir = Directory(p.join(home.path, 'cache', 'chapter', '$bookId', '0'));
      expect(dir.existsSync(), isTrue);

      await registry.invoke('Cache.PurgeBook', [bookId]);
      expect(dir.existsSync(), isFalse);
      expect((await callMap('Cache.Stats'))['chapters'], 0);
    });

    test('过期缓存的磁盘图片目录随行一起清，不留孤儿', () async {
      await callMap('Cache.Start', [bookId, 'chapters', [0]]);
      await waitJob();
      final dir = Directory(p.join(home.path, 'cache', 'chapter', '$bookId', '0'));
      expect(dir.existsSync(), isTrue);

      // 把 expires_at 改到一分钟前（模拟自动缓存到期），查出的过期行必须
      // 带着 bookUrl/index，服务层才能据此定位到图片目录删除 ——
      // 之前 purgeExpired 只删 DB 行，目录留成孤儿且下次缓存同章时旧图复活。
      // 注意手动缓存写的是 expires_at=0（永久），不会被这里清掉。
      store.daos.db.execute(
        'update `chapter_cache` set `expires_at` = ?',
        [DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60],
      );
      final expired = store.daos.chapterCache.expired();
      expect(expired, hasLength(1));
      expect(expired.first.bookUrl, '$base/b/1');
      expect(expired.first.index, 0);

      for (final item in expired) {
        final id = store.daos.book.idOf(item.bookUrl)!;
        ImageCacheService(homeDir: home.path).removeChapterDir(id, item.index);
      }
      store.daos.chapterCache.purgeExpired();

      expect(dir.existsSync(), isFalse);
      expect((await callMap('Cache.Stats'))['chapters'], 0);
    });

    test('本地漫画解压缓存纳入 Clear/PurgeBook 清理', () async {
      final comicDir = Directory(p.join(home.path, 'cache', 'comic', '$bookId'));
      comicDir.createSync(recursive: true);
      File(p.join(comicDir.path, '12.png')).writeAsBytesSync(<int>[1, 2, 3]);
      expect(comicDir.existsSync(), isTrue);

      await registry.invoke('Cache.PurgeBook', [bookId]);
      expect(comicDir.existsSync(), isFalse);

      comicDir.createSync(recursive: true);
      File(p.join(comicDir.path, '12.png')).writeAsBytesSync(<int>[1, 2, 3]);
      await registry.invoke('Cache.Clear', const []);
      expect(Directory(p.join(home.path, 'cache', 'comic')).existsSync(), isFalse);
    });
  });
}
