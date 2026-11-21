import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
import 'package:legado_core/src/service/reader/reader_service.dart';
import 'package:legado_core/src/service/setting/setting_schema.dart';
import 'package:legado_core/src/service/setting/settings_service.dart';
import 'package:legado_core/src/service/setting/settings_storage.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/source/source_fetch_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 自动缓存与离线读取（对齐原版 `BookHelp.saveContent` + `ReadBook.preDownload`）。
void main() {
  late Directory home;
  late HttpServer server;
  late String base;
  late StoreModule store;
  late ShelfModule shelf;
  late SourceFetchModule fetch;
  late ReaderModule reader;
  late Registry registry;
  late int bookId;

  /// `/c/1` 的正文，用它验证「第二次读的是缓存不是网络」。
  var chapterOneHtml = '<div id="content">正文一</div>';
  final hits = <String, int>{};

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-auto-cache');
    hits.clear();
    chapterOneHtml = '<div id="content">正文一</div>';

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      final body = switch (path) {
        '/c/1' => chapterOneHtml,
        '/c/2' => '<div id="content">正文二</div>',
        '/c/3' => '<div id="content">正文三</div>',
        _ => '<div id="content">?</div>',
      };
      request.response.headers.contentType = ContentType.html;
      request.response.write(body);
      await request.response.close();
    });

    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    fetch = SourceFetchModule();
    fetch.register(registry, ctx());
    reader = ReaderModule();
    reader.register(registry, ctx());

    // 书源只需要正文规则：目录直接写库，省掉一次抓目录。
    store.daos.bookSource.insert(
      BookSource(
        bookSourceUrl: base,
        bookSourceName: '缓存源',
        enabled: true,
        ruleContent: jsonEncode({'content': '#content@html'}),
      ),
    );
    store.daos.book.insert(
      Book(
        bookUrl: '$base/b/1',
        name: '缓存样例',
        author: '测试',
        origin: base,
        type: BookType.text,
        totalChapterNum: 3,
      ),
    );
    store.daos.chapter.insertAll([
      for (var i = 0; i < 3; i++)
        BookChapter(
          url: '$base/c/${i + 1}',
          bookUrl: '$base/b/1',
          index: i,
          title: '第${i + 1}章',
        ),
    ]);
    bookId = store.daos.book.idOf('$base/b/1')!;
  });

  tearDown(() async {
    await reader.close();
    await fetch.close();
    await shelf.close();
    await store.close();
    await server.close(force: true);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Map<String, Object?>> getContent(int index, {bool refresh = false}) async =>
      await reader.service.getContent(bookId, index, refresh: refresh);

  test('读完的章自动入库，第二次读命中缓存不再联网', () async {
    final first = await getContent(0);
    expect(first['html'], contains('正文一'));
    expect(first.containsKey('fromCache'), isFalse);
    expect(store.daos.chapterCache.get('$base/b/1', 0), isNotNull);

    // 站点改正文后再次进入同一章：应拿到缓存里的旧内容，且不再发请求。
    chapterOneHtml = '<div id="content">正文一改</div>';
    final hitsBefore = hits['/c/1'] ?? 0;
    final second = await getContent(0);
    expect(second['fromCache'], isTrue);
    expect(second['html'], contains('正文一'));
    expect(second['html'], isNot(contains('正文一改')));
    expect(hits['/c/1'], hitsBefore);

    // refresh 强制联网，覆盖缓存。
    final refreshed = await getContent(0, refresh: true);
    expect(refreshed.containsKey('fromCache'), isFalse);
    expect(refreshed['html'], contains('正文一改'));
  });

  test('方法层 Reader.GetContent 第三参 refresh=true 也会跳过缓存', () async {
    // 阅读器菜单的「刷新正文」走的就是这条路径：第三参必须被方法层认出来，
    // 否则 app 传了 true 也会被当成普通读取，用户看到「刷新了还是旧内容」。
    await getContent(0);
    chapterOneHtml = '<div id="content">正文一改</div>';
    final before = hits['/c/1'] ?? 0;

    final data = await registry.invoke('Reader.GetContent', [bookId, 0, true])
        as Map<String, Object?>;
    expect(data.containsKey('fromCache'), isFalse);
    expect(data['html'], contains('正文一改'));
    expect(hits['/c/1'], before + 1);

    // 不传第三参仍是普通读取，命中刚才刷新的那份缓存。
    final again = await registry.invoke('Reader.GetContent', [bookId, 0])
        as Map<String, Object?>;
    expect(again['fromCache'], isTrue);
  });

  test('章节 URL 变了，旧缓存不算命中', () async {
    await getContent(0);
    final cached = store.daos.chapterCache.get('$base/b/1', 0)!;
    expect(cached.url, '$base/c/1');

    // 模拟目录改版：同序号换了地址，缓存必须失效，否则读到上一版内容。
    // 主键是 (url, bookUrl)，改地址只能删了重插。
    final chapter = store.daos.chapter.getChapter('$base/b/1', 0)!;
    store.daos.chapter.deleteByBookUrl('$base/b/1');
    store.daos.chapter.insertAll([
      BookChapter(
        url: '$base/c/1?v=2',
        bookUrl: '$base/b/1',
        index: 0,
        title: chapter.title,
      ),
      for (var i = 1; i < 3; i++)
        BookChapter(
          url: '$base/c/${i + 1}',
          bookUrl: '$base/b/1',
          index: i,
          title: '第${i + 1}章',
        ),
    ]);

    final again = await getContent(0);
    expect(again.containsKey('fromCache'), isFalse);
  });

  test('自动预取后续章节（原版 +2..+N 的语义）', () async {
    await getContent(0);
    // 预取是后台任务，给事件循环几轮机会。
    for (var i = 0; i < 100; i++) {
      if (store.daos.chapterCache.get('$base/b/1', 2) != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(store.daos.chapterCache.get('$base/b/1', 2), isNotNull);
    // 当前章的下一页由阅读器自己预加载，预取队列从 +2 开始。
    expect(store.daos.chapterCache.get('$base/b/1', 1), isNull);
  });

  test('cache.autoCache=false 时不写缓存、不预取', () async {
    final settings = SettingsService(
      storage: _MemoryStorage({'cache.autoCache': 'false'}),
      schema: defaultSettingsSchema,
    );
    final service = ReaderService(
      daos: store.daos,
      shelf: shelf.service,
      sourceFetch: fetch.service,
      settings: settings,
      homeDir: home.path,
    );
    final content = await service.getContent(bookId, 0);
    expect(content['html'], contains('正文一'));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.daos.chapterCache.get('$base/b/1', 0), isNull);
    expect(store.daos.chapterCache.get('$base/b/1', 2), isNull);

    // 但用户主动要求重抓（refresh=true，阅读器刷新正文 / Cache.Start）必须落盘，
    // 否则「手动缓存」在关掉自动缓存时会变成空操作。
    chapterOneHtml = '<div id="content">正文一改</div>';
    final manual = await service.getContent(bookId, 0, refresh: true);
    expect(manual['html'], contains('正文一改'));
    expect(store.daos.chapterCache.get('$base/b/1', 0), isNotNull);
    // 仍然不预取：force 只作用于当前章。
    expect(store.daos.chapterCache.get('$base/b/1', 2), isNull);
  });

  test('cache.expireDays 会清掉过期缓存', () async {
    await getContent(0);
    // 直接把缓存时间改到 30 天前。
    final cached = store.daos.chapterCache.get('$base/b/1', 0)!;
    store.daos.chapterCache.put(
      CachedChapter(
        bookUrl: cached.bookUrl,
        index: cached.index,
        title: cached.title,
        url: cached.url,
        html: cached.html,
        images: cached.images,
        size: cached.size,
        createdAt: DateTime.now()
                .subtract(const Duration(days: 30))
                .millisecondsSinceEpoch ~/
            1000,
      ),
    );

    final settings = SettingsService(
      storage: _MemoryStorage({'cache.expireDays': '7'}),
      schema: defaultSettingsSchema,
    );
    final service = ReaderService(
      daos: store.daos,
      shelf: shelf.service,
      sourceFetch: fetch.service,
      settings: settings,
      homeDir: home.path,
    );
    await service.getContent(bookId, 0);
    // 清理只跑一次且在读取前：过期那条已被删，重新抓的这条是新的。
    final cachedAfter = store.daos.chapterCache.get('$base/b/1', 0);
    expect(cachedAfter, isNotNull);
    final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 -
        cachedAfter!.createdAt;
    expect(age, lessThan(60));
  });
}

class _MemoryStorage implements SettingsStorage {
  _MemoryStorage([Map<String, String>? seed]) : _data = {...?seed};

  final Map<String, String> _data;

  @override
  Map<String, String> getAll() => Map<String, String>.from(_data);

  @override
  String? get(String key) => _data[key];

  @override
  Future<void> putAll(Map<String, String?> patch) async {
    for (final entry in patch.entries) {
      if (entry.value == null) {
        _data.remove(entry.key);
      } else {
        _data[entry.key] = entry.value!;
      }
    }
  }

  @override
  Future<void> removeAll(List<String> keys) async {
    for (final key in keys) {
      _data.remove(key);
    }
  }
}
