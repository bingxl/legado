import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/service/shelf/shelf_module.dart';
import 'package:legado_core/src/service/source/source_fetch_module.dart';
import 'package:legado_core/src/service/source/source_module.dart';
import 'package:legado_core/src/store/store.dart';
import 'package:test/test.dart';

/// 书源抓取链路接线测试：本地 HTTP 服务模拟搜索/详情/目录页，
/// 验证 CSS 规则解析、发现分类、试读入库与转正式入架。
void main() {
  late Directory home;
  late StoreModule store;
  late ShelfModule shelf;
  late SourceModule module;
  late SourceFetchModule fetchModule;
  late Registry registry;
  late HttpServer server;
  late String base;

  LegadoContext ctx() =>
      LegadoContext(homeDir: home.path, version: 'test', host: 'test');

  final searchHtml = '''
<html><body>
<div class="item"><a class="title" href="/book/1">搜索书名</a>
<span class="author">作者甲</span><span class="intro">简介</span></div>
<div class="item"><a class="title" href="/book/2">另一本</a>
<span class="author">作者乙</span></div>
</body></html>''';

  final infoHtml = '''
<html><body><h1 class="bookname">详情书名</h1>
<span class="author">详情作者</span><div class="intro">详情简介</div>
<a class="toc" href="/toc/1">目录</a></body></html>''';

  final tocHtml = '''
<html><body>
<ul><li><a href="/ch/1">第一章 开始</a></li>
<li><a href="/ch/2">第二章 后来</a></li></ul>
</body></html>''';

  setUp(() async {
    home = await Directory.systemTemp.createTemp('legado-source-fetch');
    store = StoreModule();
    await store.migrate(ctx());
    registry = Registry();
    shelf = ShelfModule();
    shelf.register(registry, ctx());
    module = SourceModule();
    module.register(registry, ctx());
    fetchModule = SourceFetchModule();
    fetchModule.register(registry, ctx());

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'text',
        'html',
        charset: 'utf-8',
      );
      final path = request.uri.path;
      final body = switch (path) {
        '/search' => searchHtml,
        '/explore' => searchHtml,
        '/book/1' => infoHtml,
        '/toc/1' => tocHtml,
        '/ch/1' => '<div id="content">正文一</div>',
        '/ch/2' => '<div id="content">正文二</div>',
        // 文字章内嵌图片：相对地址 / 懒加载属性都要被绝对化并保留在正文里。
        '/ch/img' => '''
<div id="content">图前<img src="/static/a.jpg">图后
<img data-src="/static/b.png"></div>''',
        // nextContentUrl 串行翻页：第 1 页 → 第 2 页 → 结束。
        '/p/1' => '<div id="content">分页A</div><a class="next" href="/p/2">下一页</a>',
        '/p/2' => '<div id="content">分页B</div><a class="next" href="/p/2">下一页</a>',
        // 多链接并发分页。
        '/m/1' =>
          '<div id="content">主文</div><a class="next" href="/m/2">2</a><a class="next" href="/m/3">3</a>',
        '/m/2' => '<div id="content">并发二</div>',
        '/m/3' => '<div id="content">并发三</div>',
        _ => '<html><body>not found</body></html>',
      };
      request.response.write(body);
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await fetchModule.close();
    await module.close();
    await shelf.close();
    await store.close();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Future<Object?> call(String method, [List<Object?> args = const []]) =>
      registry.invoke(method, args);

  Future<List<Map<String, Object?>>> callList(
    String method, [
    List<Object?> args = const [],
  ]) async => (await call(method, args) as List).cast<Map<String, Object?>>();

  test('依赖与 7 个抓取方法已注册；本地管理模块不依赖 shelf', () {
    expect(fetchModule.name, 'sourcefetch');
    expect(fetchModule.dependsOn, containsAll(['store', 'source', 'shelf']));
    expect(module.dependsOn, isNot(contains('shelf')));
    final names = registry.all.map((m) => m.name).toList();
    expect(
      names,
      containsAll(<String>[
        'Source.ListExploreSources',
        'Source.ExploreKinds',
        'Source.Explore',
        'Source.Search',
        'Source.SearchAll',
        'Source.PreviewBook',
        'Source.AddToShelf',
      ]),
    );
  });

  Future<int> addSource({String? exploreUrl}) async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '测试源',
      'bookSourceGroup': '小说',
      'enabled': true,
      'enabledExplore': true,
      'customOrder': 0,
      'searchUrl': '$base/search?q={{key}}&page={{page}}',
      'exploreUrl': exploreUrl ??
          jsonEncode([
            {'title': '热门', 'url': '$base/explore?page={{page}}'},
          ]),
      'ruleSearch': jsonEncode({
        'bookList': '.item',
        'name': '.title@text',
        'author': '.author@text',
        'intro': '.intro@text',
        'bookUrl': '.title@href',
      }),
      'ruleBookInfo': jsonEncode({
        'name': '.bookname@text',
        'author': '.author@text',
        'intro': '.intro@text',
        'tocUrl': '.toc@href',
      }),
      'ruleToc': jsonEncode({
        'chapterList': 'li',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      }),
      'ruleContent': jsonEncode({'content': '#content@html'}),
    });
    final view =
        await call('Source.Save', [0, '测试源', '小说', base, '', raw, true, 0])
            as Map<String, Object?>;
    return view['id'] as int;
  }

  test('发现源列表与分类解析（纯本地）', () async {
    final id = await addSource();
    final sources = await callList('Source.ListExploreSources');
    expect(sources.length, 1);
    expect(sources.single['id'], id);
    expect(sources.single['hasExploreUrl'], isTrue);

    final kinds = await callList('Source.ExploreKinds', [id]);
    expect(kinds.length, 1);
    expect(kinds.single['title'], '热门');
    expect(kinds.single['url'], contains('/explore'));
  });

  test('<js> exploreUrl：先执行脚本再按 && / :: 切分类（超星式）', () async {
    // 超星把分类地址用脚本拼出来：标题::URL&&标题::URL，URL 自带
    // ,{...} 内嵌选项与 {{page}} 分页占位符。
    final js = r'''
<js>
u1='::/circlemarket/getBook,{"method":"POST","body":"start={{(page-1)*25}}&size=25&channelId=';
u2='"}';
list=[["❀超星推荐❀",130],["世界名著",1000000007]];
list.map(a=>a[0]+u1+a[1]+u2).join("&&")
</js>''';
    final id = await addSource(exploreUrl: js);
    final kinds = await callList('Source.ExploreKinds', [id]);

    expect(kinds.length, 2);
    expect(kinds[0]['title'], '❀超星推荐❀');
    expect(kinds[0]['url'], contains('/circlemarket/getBook,{"method":"POST"'));
    expect(kinds[0]['url'], contains('channelId=130'));
    // 分页占位符原样保留，交给 UrlRuleAnalyzer 在请求阶段替换。
    expect(kinds[0]['url'], contains('{{(page-1)*25}}'));
    expect(kinds[1]['title'], '世界名著');
    expect(kinds[1]['url'], contains('channelId=1000000007'));
    expect(kinds.every((k) => k['title'].toString().isNotEmpty), isTrue);
    expect(kinds.every((k) => k['title'].toString() != '<js>'), isTrue);
  });

  test('真实超星 exploreUrl：<js> 脚本执行后切出全部 60+ 分类', () async {
    // 直接拿书源市场里的超星完整脚本，验证箭头函数/map/join/正则 replace
    // 都能被引擎执行（这是书源真实依赖的能力）。
    final js = File('test/fixtures/chaoxing_explore.txt').readAsStringSync();
    final id = await addSource(exploreUrl: js);
    final kinds = await callList('Source.ExploreKinds', [id]);

    expect(kinds.length, 69);
    // 首类是「❀超星推荐❀」，replace(/❀/g,...) 已生效（带全角空格）。
    expect(kinds.first['title'], contains('超星推荐'));
    expect(kinds.first['title'], contains('　'));
    // 每个 URL 都带内嵌 JSON 选项与分页占位符。
    expect(
      kinds.every(
        (k) =>
            (k['url'] as String).contains('/circlemarket/getBook,{') &&
            (k['url'] as String).contains('channelId=') &&
            (k['url'] as String).contains('{{(page-1)*25}}'),
      ),
      isTrue,
    );
    // 不同分类带不同 channelId（脚本按 list 拼装成功）。
    final channelIds = kinds
        .map((k) => RegExp(r'channelId=(\d+)').firstMatch('${k['url']}')?.group(1))
        .toSet();
    expect(channelIds.length, 69);
  });

  test('@js: exploreUrl：脚本输出 JSON 数组', () async {
    final id = await addSource(
      exploreUrl: r'''@js:'[{"title":"玄幻","url":"/a?page={{page}}"},{"title":"都市","url":"/b"}]' ''',
    );
    final kinds = await callList('Source.ExploreKinds', [id]);
    expect(kinds.length, 2);
    expect(kinds[0]['title'], '玄幻');
    expect(kinds[0]['url'], contains('/a?page'));
    expect(kinds[1]['title'], '都市');
  });

  test('<js> exploreUrl 执行失败时不把脚本文本当分类', () async {
    final id = await addSource(
      exploreUrl: r'<js>throw new Error("boom")</js>',
    );
    final kinds = await callList('Source.ExploreKinds', [id]);
    expect(kinds.length, 1);
    expect(kinds.first['title'], startsWith('ERROR:'));
    expect(kinds.first['url'], isNotEmpty);
  });

  test('Search 用 CSS 规则解析搜索结果', () async {
    final id = await addSource();
    final results = await callList('Source.Search', [id, '关键词', 1]);
    expect(results.length, 2);
    expect(results.first['name'], '搜索书名');
    expect(results.first['author'], '作者甲');
    expect(results.first['bookUrl'], '$base/book/1');
    expect(results.first['origin'], base);
    expect(results.first['originName'], '测试源');

    await expectLater(
      call('Source.Search', [id, '', 1]),
      throwsA(
        isA<LegadoException>().having((e) => e.code, 'code', ErrorCode.invalid),
      ),
    );
  });

  test('Explore 走分类 URL，也返回搜索结果结构', () async {
    final id = await addSource();
    final results = await callList('Source.Explore', [id, '', 1]);
    expect(results.length, 2);
    expect(results.first['bookUrl'], '$base/book/1');
  });

  test('SearchAll 汇总启用源', () async {
    final id = await addSource();
    expect(id, greaterThan(0));
    final results = await callList('Source.SearchAll', ['关键词', 1]);
    expect(results.length, 2);
  });

  test('PreviewBook 入库但不在书架；AddToShelf 转正', () async {
    final id = await addSource();
    final preview =
        await call('Source.PreviewBook', [
              id,
              '$base/book/1',
              '搜索书名',
              '作者甲',
              '{}',
            ])
            as Map<String, Object?>;
    expect(preview['name'], '详情书名');
    expect(preview['author'], '详情作者');
    expect(preview['inShelf'], isFalse);
    expect(preview['totalChapters'], 2);

    final inShelf = await callList('Shelf.ListBooks', [0]);
    expect(inShelf, isEmpty);

    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/1',
              '搜索书名',
              '作者甲',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    expect(added['inShelf'], isTrue);
    expect((await callList('Shelf.ListBooks', [0])).length, 1);
    expect(store.daos.chapter.getChapterCount('$base/book/1'), 2);
  });

  test('PreviewBook 详情无 coverUrl 时沿用列表页封面（超星式）', () async {
    final id = await addSource();
    const cover = 'https://img.test/cover.jpg';
    final preview =
        await call('Source.PreviewBook', [
              id,
              '$base/book/1',
              '另一本',
              '作者乙',
              '{}',
              cover,
            ])
            as Map<String, Object?>;
    expect(preview['cover'], cover);

    // 再打开同一本（已入库）也不该把封面冲掉。
    final again =
        await call('Source.PreviewBook', [
              id,
              '$base/book/1',
              '另一本',
              '作者乙',
              '{}',
              cover,
            ])
            as Map<String, Object?>;
    expect(again['cover'], cover);
  });

  /// 造一个只测正文的书源：ruleContent 里带 content + nextContentUrl。
  Future<void> addContentSource(String nextRule) async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '正文源',
      'enabled': true,
      'ruleContent': jsonEncode({
        'content': '#content@html',
        'nextContentUrl': nextRule,
      }),
    });
    await call('Source.Save', [0, '正文源', '', base, '', raw, true, 0]);
  }

  test('fetchContent 按 nextContentUrl 串行追页并去重防环', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final (html, _) = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/p/1',
      // 下一章与分页无关，不应影响追页。
      nextChapterUrl: '$base/ch/9',
    );
    expect(html, contains('分页A'));
    expect(html, contains('分页B'));
    // /p/2 的下一页仍指向自己，必须去重停下，不能无限循环。
    expect(html.split('分页B').length, 2);
  });

  test('fetchContent 把正文内联图片绝对化，同时保留在 HTML 中', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final (html, images) = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/img',
    );

    expect(images, contains('$base/static/a.jpg'));
    expect(images, contains('$base/static/b.png'));
    // 内联图不能被剔除，否则文字章会丢图；相对 src 要换成绝对地址。
    expect(html, contains('src="$base/static/a.jpg"'));
    expect(html, contains('图前'));
    expect(html, contains('图后'));
  });

  test('fetchContent 按 nextContentUrl 多链接并发抓页', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final (html, _) = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/m/1',
    );
    expect(html, contains('主文'));
    expect(html, contains('并发二'));
    expect(html, contains('并发三'));
  });

  test('AddBookByUrl 按域名匹配书源，解析详情页并入库', () async {
    final id = await addSource();
    expect(id, greaterThan(0));
    final result = await call('Source.AddBookByUrl', [
      '$base/book/1',
      0,
    ]) as Map<String, Object?>;
    final success = (result['success'] as List).cast<Map<String, Object?>>();
    expect(success.length, 1);
    expect(success.first['url'], '$base/book/1');
    final brief = success.first['book'] as Map<String, Object?>;
    expect(brief['name'], '详情书名');

    // 再添一次应报"书籍已存在"。
    final again = await call('Source.AddBookByUrl', ['$base/book/1', 0])
        as Map<String, Object?>;
    expect((again['failed'] as List).length, 1);
  });

  test('AddBookByUrl 无匹配书源时逐行记失败', () async {
    final result = await call('Source.AddBookByUrl', [
      'https://no-such-source.example/book/1',
      0,
    ]) as Map<String, Object?>;
    expect((result['success'] as List), isEmpty);
    final failed = (result['failed'] as List).cast<Map<String, Object?>>();
    expect(failed.length, 1);
    expect(failed.first['reason'], contains('未找到匹配书源'));
  });

  test('fetchContent 遇到 nextChapterUrl 边界就停止追页', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    // 让 /p/1 的下一页正好等于“下一章地址”，应立刻停止，不抓 /p/2。
    final (html, _) = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/p/1',
      nextChapterUrl: '$base/p/2',
    );
    expect(html, contains('分页A'));
    expect(html, isNot(contains('分页B')));
  });
}
