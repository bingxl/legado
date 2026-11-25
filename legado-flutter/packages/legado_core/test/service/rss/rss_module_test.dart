import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/rss/rss_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// RSS 域接线测试：源 CRUD、文章已读/收藏、XML 拉取、未读统计。
void main() {
  late Directory home;
  late StoreModule store;
  late RssModule module;
  late Registry registry;
  late HttpServer server;
  late String feedUrl;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  const feed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel>
<title>测试订阅</title>
<item><title>第一篇</title><link>http://example.test/1</link>
<description>摘要一</description><pubDate>Mon, 18 Nov 2026 10:00:00 +0800</pubDate></item>
<item><title>第二篇</title><link>http://example.test/2</link>
<description>摘要二</description></item>
</channel></rss>''';

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-rss-module');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    module = RssModule();
    module.register(registry, ctx());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
        ..headers.contentType = ContentType('application', 'rss+xml', charset: 'utf-8')
        ..write(feed);
      await request.response.close();
    });
    feedUrl = 'http://127.0.0.1:${server.port}/feed.xml';
  });

  tearDown(() async {
    await server.close(force: true);
    await module.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as List).cast<Map<String, Object?>>();

  Future<Map<String, Object?>> callMap(String method,
          [List<Object?> args = const []]) async =>
      (await call(method, args) as Map).cast<String, Object?>();

  Future<int> addSource([String? url]) async {
    final view = await callMap('Rss.Source.Save', [
      {
        'id': 0,
        'name': '测试源',
        'url': url ?? feedUrl,
        'group': '新闻',
        'sortOrder': 1,
      },
    ]);
    return view['id'] as int;
  }

  test('依赖与 12 个方法注册', () {
    expect(module.name, 'rss');
    expect(module.dependsOn, contains('store'));
    expect(
      registry.all.map((m) => m.name),
      containsAll(<String>[
        'Rss.Source.List',
        'Rss.Source.Save',
        'Rss.Source.Delete',
        'Rss.Source.SetEnabled',
        'Rss.Article.List',
        'Rss.Article.Refresh',
        'Rss.Article.MarkRead',
        'Rss.Article.Favorite',
        'Rss.Favorite.List',
        'Rss.Favorite.Groups',
        'Rss.Favorite.Remove',
        'Rss.Unread.Count',
      ]),
    );
  });

  test('源 CRUD：单参数对象、enabled 省略不改、删除连带文章', () async {
    final id = await addSource();
    var sources = await callList('Rss.Source.List');
    expect(sources.single['name'], '测试源');
    expect(sources.single['unreadCount'], 0);

    await call('Rss.Source.Save', [
      {'id': id, 'name': '改名', 'url': feedUrl, 'group': '新闻'},
    ]);
    sources = await callList('Rss.Source.List');
    expect(sources.single['name'], '改名');
    expect(sources.single['enabled'], isTrue); // 省略不改

    await call('Rss.Source.SetEnabled', [id, false]);
    expect((await callList('Rss.Source.List')).single['enabled'], isFalse);

    await call('Rss.Source.Delete', [id]);
    expect(await callList('Rss.Source.List'), isEmpty);
  });

  test('Refresh 解析 RSS 并落库；重复刷新不新增；已读/收藏切换', () async {
    final id = await addSource();
    final result = await callMap('Rss.Article.Refresh', [id]);
    expect(result['sources'], 1);
    expect(result['added'], 2);
    expect(result['errors'], isEmpty);

    var articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    expect(articles.length, 2);
    expect(articles.first['title'], '第一篇');
    expect(articles.first['sourceId'], id);
    expect(articles.first['favorite'], isFalse);

    final again = await callMap('Rss.Article.Refresh', [id]);
    expect(again['added'], 0);
    expect(again['updated'], 2);

    final articleId = articles.first['id'] as int;
    await call('Rss.Article.MarkRead', [articleId, true]);
    articles = await callList('Rss.Article.List', [id, true, 0, 20]);
    expect(articles.length, 1);
    articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    expect(articles.firstWhere((a) => a['id'] == articleId)['read'], isTrue);

    final favState = await call('Rss.Article.Favorite', [articleId]);
    expect(favState, isTrue);
    expect((await callList('Rss.Favorite.List')).length, 1);
    expect(await call('Rss.Article.Favorite', [articleId]), isFalse);
    expect(await callList('Rss.Favorite.List'), isEmpty);

    final counts = await call('Rss.Unread.Count') as Map<String, Object?>;
    expect(counts['$id'], 1);
  });

  test('收藏列表覆盖默认分组，回填真实文章 id，可按 (origin, link) 取消', () async {
    // 不传 group 的源 → sourceGroup 为空 → 文章 group 落到「默认分组」。
    final view = await callMap('Rss.Source.Save', [
      {'id': 0, 'name': '默认组源', 'url': feedUrl},
    ]);
    final id = view['id'] as int;
    await call('Rss.Article.Refresh', [id]);
    final articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    final articleId = articles.first['id'] as int;
    await call('Rss.Article.Favorite', [articleId]);

    // 全部：默认分组的收藏必须在，且 id 是真实 rowid（否则星标点了没反应）。
    final all = await callList('Rss.Favorite.List');
    expect(all.length, 1);
    expect(all.single['group'], '默认分组');
    expect(all.single['id'], articleId);
    expect(all.single['favorite'], isTrue);
    expect(all.single['origin'], feedUrl);

    // 按分组：默认分组单独查得到同一条（旧实现 byGroup('') 恒空 → 收藏消失）。
    final byDefault = await callList('Rss.Favorite.List', ['默认分组']);
    expect(byDefault.length, 1);
    final groups = await call('Rss.Favorite.Groups') as List;
    expect(groups, contains('默认分组'));

    // 另一组查不到。
    expect(await callList('Rss.Favorite.List', ['新闻']), isEmpty);

    // 按 (origin, link) 取消（文章行被清理、id 为 0 时的兜底路径）。
    await call('Rss.Favorite.Remove', [feedUrl, all.single['link']]);
    expect(await callList('Rss.Favorite.List'), isEmpty);
  });

  test('pubDate 解析成 Unix 秒：RFC822 带时区 / Atom ISO8601', () async {
    final id = await addSource();
    await call('Rss.Article.Refresh', [id]);
    final articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    final first = articles.firstWhere((a) => a['title'] == '第一篇');
    // 2026-11-18T10:00:00+08:00 == 2026-11-18T02:00:00Z
    expect(
      first['pubDate'],
      DateTime.utc(2026, 11, 18, 2).millisecondsSinceEpoch ~/ 1000,
    );
    // 没写 pubDate 的文章给 0，UI 会隐藏时间。
    final second = articles.firstWhere((a) => a['title'] == '第二篇');
    expect(second['pubDate'], 0);
  });

  test('刷新后 order 单调：新一轮文章排在旧文章前面', () async {
    final id = await addSource();
    await call('Rss.Article.Refresh', [id]);
    var articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    final firstTitles = [for (final a in articles) a['title']];
    expect(firstTitles.first, '第一篇');

    // 源换成只含一篇新文章的 feed：新文章必须排在最前。
    final newFeed = '''<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>测试订阅</title>
<item><title>第三篇</title><link>http://example.test/3</link>
<description>摘要三</description></item>
</channel></rss>''';
    final newServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    newServer.listen((request) async {
      request.response
        ..headers.contentType =
            ContentType('application', 'rss+xml', charset: 'utf-8')
        ..write(newFeed);
      await request.response.close();
    });
    addTearDown(() async => newServer.close(force: true));

    await call('Rss.Source.Save', [
      {
        'id': id,
        'name': '测试源',
        'url': 'http://127.0.0.1:${newServer.port}/feed.xml',
        'group': '新闻',
      },
    ]);
    await call('Rss.Article.Refresh', [id]);
    articles = await callList('Rss.Article.List', [id, false, 0, 20]);
    expect(articles.first['title'], '第三篇');
  });

  test('sourceId=0 刷新全部启用源；分页 offset 在 limit 前', () async {
    final id = await addSource();
    await call('Rss.Article.Refresh', [id]);
    final first = await callList('Rss.Article.List', [0, false, 0, 1]);
    expect(first.length, 1);
    final second = await callList('Rss.Article.List', [0, false, 1, 1]);
    expect(second.length, 1);
    expect(second.single['id'], isNot(first.single['id']));

    await call('Rss.Source.SetEnabled', [id, false]);
    final result = await callMap('Rss.Article.Refresh', [0]);
    expect(result['sources'], 0);
  });

  test('未知源/文章抛 NOT_FOUND', () async {
    await expectLater(
      call('Rss.Source.Delete', [9999]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.notFound)),
    );
    await expectLater(
      call('Rss.Article.MarkRead', [9999, true]),
      throwsA(isA<LegadoException>()
          .having((e) => e.code, 'code', ErrorCode.notFound)),
    );
  });
}
