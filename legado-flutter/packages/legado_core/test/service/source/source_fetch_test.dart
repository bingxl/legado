import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
import 'package:legado_core/src/net/net.dart';
import 'package:legado_core/src/service/reader/reader_module.dart';
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

  /// 「更新目录 / 刷新详情」用例会在测试中改写这两个页面，模拟站点更新。
  late String tocRefreshHtml;
  late String infoRefreshHtml;

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

  // 换源目标：另一个书源（bookSourceUrl 不同）指向另一套详情/目录。
  final infoHtmlB = '''
<html><body><h1 class="bookname">换源书名</h1>
<span class="author">换源作者</span><div class="intro">换源简介</div>
<a class="toc" href="/toc/2">目录</a></body></html>''';

  final tocHtmlB = '''
<html><body>
<ul><li><a href="/ch/21">第一章 新开始</a></li>
<li><a href="/ch/22">第二章 新后来</a></li>
<li><a href="/ch/23">第三章 新结局</a></li></ul>
</body></html>''';

  // 旧站目录常见结构：顶部「最新章节」区块 + 正文全量目录，同一 URL 出现两次。
  final infoHtmlDup = '''
<html><body><h1 class="bookname">重复目录</h1>
<span class="author">作者丙</span><div class="intro">简介</div>
<a class="toc" href="/toc/dup">目录</a></body></html>''';

  final tocDupHtml = '''
<html><body>
<ul class="new">
<li><a href="/ch/3">第三章 尾</a></li>
<li><a href="/ch/4">第四章 尾</a></li>
</ul>
<ul class="all">
<li><a href="/ch/1">第一章</a></li>
<li><a href="/ch/2">第二章</a></li>
<li><a href="/ch/3">第三章 尾</a></li>
<li><a href="/ch/4">第四章 尾</a></li>
</ul>
</body></html>''';

  final infoHtmlPaged = '''
<html><body><h1 class="bookname">分页目录</h1>
<span class="author">作者丁</span><div class="intro">简介</div>
<a class="toc" href="/toc/p1">目录</a></body></html>''';

  final tocPage1 = '''
<html><body><ul>
<li><a href="/ch/1">第一章</a></li>
<li><a href="/ch/2">第二章</a></li>
</ul><a class="next" href="/toc/p2">下一页</a></body></html>''';

  final tocPage2 = '''
<html><body><ul>
<li><a href="/ch/3">第三章</a></li>
<li><a href="/ch/4">第四章</a></li>
</ul></body></html>''';

  // `-` 前缀：规则返回倒序（最新章在前）。
  final infoHtmlRev = '''
<html><body><h1 class="bookname">倒序目录</h1>
<span class="author">作者戊</span><div class="intro">简介</div>
<a class="toc" href="/toc/rev">目录</a></body></html>''';

  final tocRevHtml = '''
<html><body><ul>
<li><a href="/ch/4">第四章</a></li>
<li><a href="/ch/3">第三章</a></li>
<li><a href="/ch/2">第二章</a></li>
<li><a href="/ch/1">第一章</a></li>
</ul></body></html>''';

  // 详情页初始化规则：页面里书名/作者用的是自定义标签，
  // 必须靠 `ruleBookInfo.init` 换成标准结构后才能被字段规则命中。
  final infoHtmlInit = '''
<html><body>
<bookname>初始化书名</bookname><author>初始化作者</author>
<a class="toc" href="/toc/1">目录</a>
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
    ReaderModule().register(registry, ctx());

    tocRefreshHtml = tocHtml;
    infoRefreshHtml = '''
<html><body><h1 class="bookname">刷新书名</h1>
<span class="author">作者甲</span><div class="intro">简介</div>
<a class="toc" href="/toc/refresh">目录</a></body></html>''';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType(
        'text',
        'html',
        charset: 'utf-8',
      );
      final path = request.uri.path;
      // 反爬端点：普通请求一律 403 + cf-mitigated: challenge，
      // 只有带上验证得到的 cf_clearance 才给正文。
      // `/locked-hard` 模拟「验证也拿不到 cf_clearance」的自建验证站。
      if (path == '/locked' || path == '/locked-hard') {
        final cookie = request.headers.value('cookie') ?? '';
        if (path == '/locked' && cookie.contains('cf_clearance=good')) {
          request.response.write('<div id="content">重抓正文</div>');
        } else {
          request.response.statusCode = 403;
          request.response.headers.set('cf-mitigated', 'challenge');
          request.response.write('<html>challenge</html>');
        }
        await request.response.close();
        return;
      }
      final body = switch (path) {
        '/search' => searchHtml,
        // 真实书源大多把整个查询串当书名关键词；这个端点只在 q 恰好等于
        // 书名时返回结果，用来锁住「精确搜索只传书名、作者仅做过滤」的行为。
        '/strictsearch' => request.uri.queryParameters['q'] == '搜索书名'
            ? searchHtml
            : '<html><body></body></html>',
        // 第二个书源用不同域名前缀做搜索；详情页会把书名改成「详情书名」，
        // 所以这里的搜索结果也用同名同作者，才能测到精确搜索命中。
        '/altsearch' => '''
<html><body>
<div class="item"><a class="title" href="/book/1">详情书名</a>
<span class="author">详情作者</span><span class="intro">简介</span></div>
</body></html>''',
        '/explore' => searchHtml,
        '/book/1' => infoHtml,
        '/toc/1' => tocHtml,
        '/book/refresh' => infoRefreshHtml,
        '/toc/refresh' => tocRefreshHtml,
        '/book/2' => infoHtmlB,
        '/toc/2' => tocHtmlB,
        '/book/dup' => infoHtmlDup,
        '/toc/dup' => tocDupHtml,
        '/book/paged' => infoHtmlPaged,
        '/toc/p1' => tocPage1,
        '/toc/p2' => tocPage2,
        '/book/rev' => infoHtmlRev,
        '/toc/rev' => tocRevHtml,
        '/book/init' => infoHtmlInit,
        '/api' => '{"api":1}',
        '/ch/1' => '<div id="content">正文一</div>',
        // 标题只在正文页才完整的源（ruleContent.title）。
        '/ch/named' =>
          '<h1 class="ct">第一章 真正的标题</h1><div id="content">正文有标题</div>',
        '/ch/2' => '<div id="content">正文二</div>',
        '/ch/3' => '<div id="content">正文三</div>',
        '/ch/4' => '<div id="content">正文四</div>',
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
        'Source.ChangeSource',
      ]),
    );
  });

  Future<int> addSource({
    String? exploreUrl,
    String? jsLib,
    String? bookSourceUrl,
    String searchPath = '/search',
    String name = '测试源',
    String group = '小说',
    String? loginCheckJs,
    Map<String, Object?>? ruleToc,
    Map<String, Object?>? ruleBookInfo,
  }) async {
    final sourceUrl = bookSourceUrl ?? base;
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': sourceUrl,
      'bookSourceName': name,
      'bookSourceGroup': group,
      'enabled': true,
      'enabledExplore': true,
      'customOrder': 0,
      'searchUrl': '$sourceUrl$searchPath?q={{key}}&page={{page}}',
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
      'ruleBookInfo': jsonEncode(ruleBookInfo ??
          {
            'name': '.bookname@text',
            'author': '.author@text',
            'intro': '.intro@text',
            'tocUrl': '.toc@href',
          }),
      'ruleToc': jsonEncode(ruleToc ??
          {
            'chapterList': 'li',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          }),
      'ruleContent': jsonEncode({'content': '#content@html'}),
      if (jsLib != null) 'jsLib': jsLib,
      if (loginCheckJs != null) 'loginCheckJs': loginCheckJs,
    });
    final view =
        await call('Source.Save', [
              0,
              name,
              group,
              sourceUrl,
              '',
              raw,
              true,
              0,
            ])
            as Map<String, Object?>;
    return view['id'] as int;
  }

  test('Source.BatchChangeSource 按书名+作者精确搜索后逐本换源', () async {
    final srcA = await addSource(name: '源甲');
    // 目标源用不同 URL，但搜索页仍返回同一本书；换源只换 origin，不换 bookUrl。
    final srcB = await addSource(
      name: '源乙',
      bookSourceUrl: '$base/alt',
      searchPath: 'search',
    );
    final added =
        await call('Source.AddToShelf', [
              srcA,
              '$base/book/1',
              '搜索书名',
              '作者甲',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    expect(store.daos.book.getById(added['id'] as int)!.origin, base);

    final result =
        await call('Source.BatchChangeSource', [
              [added['id']],
              srcB,
            ])
            as Map<String, Object?>;
    expect(result['succeeded'], 1);
    expect(result['failed'], 0);
    expect(store.daos.book.getByUrl('$base/book/1')!.origin, '$base/alt');
    // 换源后目录按新源重抓，仍是两章但章节 URL 一致；进度不应丢。
    expect(store.daos.chapter.getChapterCount('$base/book/1'), 2);
  });

  test('Source.ImportBookshelf 按书名+作者搜索加书并跳过已存在', () async {
    // addSource 只为注册书源（有副作用），返回值这里用不上。
    await addSource();
    final doc = jsonEncode([
      {'name': '搜索书名', 'author': '作者甲', 'intro': '简介'},
      {'name': '另一本', 'author': '作者乙'},
      {'name': '', 'author': '无效'},
    ]);
    final result =
        await call('Source.ImportBookshelf', [doc, 2]) as Map<String, Object?>;
    expect(result['added'], 2);
    expect(result['skipped'], 1); // 空书名
    expect(result['failed'], 0);
    expect(store.daos.book.getByUrl('$base/book/1'), isNotNull);
    expect(store.daos.book.getByUrl('$base/book/2'), isNotNull);
    // groupID 是位域，2 对应自建分组。
    expect(store.daos.book.getByUrl('$base/book/1')!.group, 2);

    // 再导一次：同名同作者直接跳过，不会重复入库。
    final again =
        await call('Source.ImportBookshelf', [
              jsonEncode([
                {'name': '另一本', 'author': '作者乙'},
              ]),
              0,
            ])
            as Map<String, Object?>;
    expect(again['skipped'], 1, reason: '详情改名后按命中 URL 也要能查重');
  });

  test('Source.ImportBookshelf 只用书名搜索，作者仅过滤结果', () async {
    // 早期实现把关键词拼成「书名 作者」，多数书源会因此搜到 0 条，
    // 表现为导入完成但书架没有书。这里用严格匹配端点复现真实站点行为。
    await addSource(searchPath: '/strictsearch');
    final result = await call('Source.ImportBookshelf', [
          jsonEncode([
            {'name': '搜索书名', 'author': '作者甲'},
          ]),
          0,
        ]) as Map<String, Object?>;
    expect(result['added'], 1, reason: '关键词必须是书名本身，不能拼作者');
    expect(result['skipped'], 0);
    expect(result['failed'], 0);
    expect(store.daos.book.getByUrl('$base/book/1'), isNotNull);
  });

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

  test('jsLib 里的函数在 exploreUrl 脚本中可用', () async {
    // jsLib 是书源的公共函数库。没注入时这里会抛 ReferenceError，
    // 整条 discover 链退化成 ERROR 分类。
    final id = await addSource(
      exploreUrl: r'<js>buildKinds()</js>',
      jsLib: r'function buildKinds(){ return "科幻::/k?page={{page}}&&武侠::/w"; }',
    );
    final kinds = await callList('Source.ExploreKinds', [id]);
    expect(kinds.length, 2);
    expect(kinds[0]['title'], '科幻');
    expect(kinds[0]['url'], contains('/k?page'));
    expect(kinds[1]['title'], '武侠');
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

  test('SearchAll 按原版 SearchScope 格式筛选：单源 / 分组 / 无效回退', () async {
    await addSource(name: '甲源', group: '小说');
    await addSource(
      name: '乙源',
      group: '漫画',
      bookSourceUrl: '$base/alt',
      searchPath: 'search',
    );

    expect(await callList('Source.SearchAll', ['关键词', 1]), hasLength(3));

    // name::url 按地址取源；名称只用于展示，写错也不影响命中。
    final byUrl = await callList('Source.SearchAll', [
      '关键词',
      1,
      '名字写错了::$base',
    ]);
    expect(byUrl, hasLength(2));

    // 逗号分隔的多个分组取并集，单个分组只取该组。
    expect(
      await callList('Source.SearchAll', ['关键词', 1, '小说,漫画']),
      hasLength(3),
    );
    expect(
      await callList('Source.SearchAll', ['关键词', 1, '漫画']),
      hasLength(1),
    );

    // 分组被删空后回退全部启用源，不能让用户以为书全没了。
    expect(
      await callList('Source.SearchAll', ['关键词', 1, '不存在的分组']),
      hasLength(3),
    );
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

  test('RefreshToc：重抓目录整章替换，保留进度并汇总变化', () async {
    final sourceId = await addSource();
    final url = '$base/book/refresh';
    final preview = await call('Source.PreviewBook', [
      sourceId,
      url,
      '刷新书名',
      '作者甲',
      '{}',
    ]) as Map<String, Object?>;
    final id = preview['id'] as int;
    await call('Shelf.PutOnShelf', [id]);
    await call('Shelf.SaveProgress', [id, 0, '第一章 开始', 12, 33.0]);
    expect(store.daos.chapter.getUrls(url).length, 2);

    tocRefreshHtml = '''
<html><body><ul>
<li><a href="/ch/1">第一章 开始（改）</a></li>
<li><a href="/ch/2">第二章 后来</a></li>
<li><a href="/ch/5">第三章 新章</a></li>
</ul></body></html>''';

    final result =
        await call('Source.RefreshToc', [id]) as Map<String, Object?>;
    expect(result['total'], 3);
    expect(result['added'], 1);
    expect(result['removed'], 0);
    expect(result['hasUpdate'], isTrue);

    final chapters = store.daos.chapter.getChapterList(url);
    expect(chapters.length, 3);
    expect(chapters.map((c) => c.index).toList(), [0, 1, 2]);
    expect(chapters.last.title, '第三章 新章');
    final progress =
        await call('Shelf.GetProgress', [id]) as Map<String, Object?>;
    expect(progress['chapterIndex'], 0);
    expect(progress['chapterPos'], 12);
    expect(progress['scrollPercent'], 33.0);
    expect(progress['chapterTitle'], '第一章 开始（改）');

    // 有新章：原版 BookChapterList 会写 latestChapterTime 与 lastCheckCount，
    // 书架「更新」角标与「N 章未读」全靠这两个字段。
    var book = store.daos.book.getById(id)!;
    expect(book.latestChapterTime, greaterThan(0));
    expect(book.lastCheckCount, 1); // 3 - 之前 2 章
    final stamp = book.latestChapterTime;

    // 再刷一次没有新章：latestChapterTime 不能变（否则角标一直亮着）。
    final again =
        await call('Source.RefreshToc', [id]) as Map<String, Object?>;
    expect(again['hasUpdate'], isFalse);
    book = store.daos.book.getById(id)!;
    expect(book.latestChapterTime, stamp);
  });

  test('RefreshBook：详情页刷新重抓详情+目录，不改名也不覆盖自定义字段', () async {
    final sourceId = await addSource();
    final url = '$base/book/refresh';
    final preview = await call('Source.PreviewBook', [
      sourceId,
      url,
      '刷新书名',
      '作者甲',
      '{}',
    ]) as Map<String, Object?>;
    final id = preview['id'] as int;
    await call('Shelf.PutOnShelf', [id]);
    await call('Shelf.SaveProgress', [id, 0, '第一章 开始', 7, 15.0]);

    // 用户改过书名（canReName=false，刷新后不能被站点的「站点新书名」冲掉）。
    await call('Shelf.SaveBook', [id, '我改的书名', '作者甲', '', '', -1]);

    // 站点同时更新了简介与目录。
    infoRefreshHtml = '''
<html><body><h1 class="bookname">站点新书名</h1>
<span class="author">站点新作者</span><div class="intro">站点新简介</div>
<a class="toc" href="/toc/refresh">目录</a></body></html>''';
    tocRefreshHtml = '''
<html><body><ul>
<li><a href="/ch/1">第一章 开始（改）</a></li>
<li><a href="/ch/2">第二章 后来</a></li>
<li><a href="/ch/5">第三章 新章</a></li>
</ul></body></html>''';

    final result =
        await call('Source.RefreshBook', [id]) as Map<String, Object?>;
    expect(result['detailUpdated'], isTrue);
    expect(result['total'], 3);
    expect(result['added'], 1);
    expect(result['hasUpdate'], isTrue);

    var book = store.daos.book.getById(id)!;
    // canReName=false：书名/作者不跟站点改。
    expect(book.name, '我改的书名');
    expect(book.author, '作者甲');
    // 没有自定义简介时，书源字段应被重抓更新 —— 证明「刷新」真去抓了详情。
    expect(book.intro, '站点新简介');
    // 目录确实重抓了。
    expect(store.daos.chapter.getChapterCount(url), 3);

    // 进度按序号保留并同步标题。
    final progress =
        await call('Shelf.GetProgress', [id]) as Map<String, Object?>;
    expect(progress['chapterIndex'], 0);
    expect(progress['chapterPos'], 7);
    expect(progress['chapterTitle'], '第一章 开始（改）');

    // 再设自定义简介后刷新：用户字段优先，不被站点值覆盖。
    await call('Shelf.SaveBook', [
      id,
      '我改的书名',
      '作者甲',
      '',
      '用户自定义简介',
      -1,
    ]);
    await call('Source.RefreshBook', [id]);
    book = store.daos.book.getById(id)!;
    expect(book.customIntro, '用户自定义简介');
    expect(book.intro, '站点新简介', reason: 'customIntro 存在时展示值仍由 displayIntro 决定');
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
  Future<void> addContentSource(
    String nextRule, {
    String? titleRule,
    String contentRule = '#content@html',
  }) async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '正文源',
      'enabled': true,
      'ruleContent': jsonEncode({
        'content': contentRule,
        'nextContentUrl': nextRule,
        if (titleRule != null) 'title': titleRule,
      }),
    });
    await call('Source.Save', [0, '正文源', '', base, '', raw, true, 0]);
  }

  test('fetchContent 解出 ruleContent.title 并回写章节标题', () async {
    await addContentSource('a.next@href', titleRule: 'h1.ct@text');
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/named',
      chapterTitle: '第1章',
    );
    expect(fetched.title, '第一章 真正的标题');
    expect(fetched.html, contains('正文有标题'));

    // 没配 title 规则时不产出标题（上层继续用目录里的）。
    await addContentSource('');
    final source2 = fetchModule.service.sourceByUrl(base)!;
    final plain = await fetchModule.service.fetchContent(
      source2,
      '$base/book/1',
      '$base/ch/1',
    );
    expect(plain.title, isNull);
  });

  test('java.startBrowserAwait：验证后回填 cookie 并重抓正文', () async {
    final seen = <BrowserVerificationRequest>[];
    HostVerification.register((request) async {
      seen.add(request);
      return const BrowserVerificationResult(
        cookie: 'cf_clearance=good',
        userAgent: 'UA-BROWSER',
        html: '<div id="content">浏览器正文</div>',
      );
    });
    addTearDown(() => HostVerification.register(null));

    await addContentSource(
      '',
      contentRule:
          "@js: java.startBrowserAwait('$base/locked', '验证一下').body()",
    );
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/1',
    );

    expect(
      fetched.html,
      contains('重抓正文'),
      reason: 'refetchAfterSuccess 默认 true：要用内核重抓，而不是拿浏览器 outerHTML',
    );
    expect(seen.single.uri.path, '/locked');
    expect(seen.single.title, '验证一下');
    expect(
      seen.single.headers.containsKey('cookie'),
      isFalse,
      reason: 'Cookie 由浏览器自己的 jar 管，塞进去会和它打架',
    );
    // 凭证落盘：同一 host 的后续请求直接可用（这里靠 mock 的 cookie 判定验证）。
    expect(
      fetchModule.service.net.cookies.cookieValue(
        Uri.parse(base),
        'cf_clearance',
      ),
      'good',
    );
    expect(
      fetchModule.service.net.guard.state.userAgentFor('127.0.0.1'),
      'UA-BROWSER',
    );
  });

  test('java.startBrowserAwait：重抓仍被拦截时退回浏览器 HTML', () async {
    HostVerification.register(
      (request) async => const BrowserVerificationResult(
        html: '<div id="content">浏览器正文</div>',
      ),
    );
    addTearDown(() => HostVerification.register(null));

    // 站点即使过了验证也不发 cf_clearance（自建验证 / 只有 __cf_bm）：
    // 重抓必然还是挑战页，此时浏览器渲染结果才是对的。
    await addContentSource(
      '',
      contentRule:
          "@js: java.startBrowserAwait('$base/locked-hard', '验证').body()",
    );
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/1',
    );
    expect(fetched.html, contains('浏览器正文'));
  });

  test('java.startBrowser：不等结果，只要求宿主开窗', () async {
    final opened = <BrowserVerificationRequest>[];
    HostVerification.register((request) async {
      opened.add(request);
      return const BrowserVerificationResult(skipped: true);
    });
    addTearDown(() => HostVerification.register(null));

    await addContentSource(
      '',
      // 开窗后照常用当前页的结果（`result` 是规则层的原始 HTML）。
      contentRule: "@js: java.startBrowser('$base/locked', '登录'); result",
    );
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/1',
    );

    // 脚本没被阻塞：正文还是当前页的，窗口是「后台打开」的。
    expect(fetched.html, contains('正文一'));
    expect(opened.single.uri.path, '/locked');
  });

  test('书源 concurrentRate 生效：同一书源的第二次请求要等窗口', () async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '限速源',
      'enabled': true,
      'concurrentRate': '1/250',
    });
    await call('Source.Save', [0, '限速源', '', base, '', raw, true, 0]);
    final source = fetchModule.service.sourceByUrl(base)!;
    expect(source.concurrentRate, '1/250');
    final sw = Stopwatch()..start();
    await fetchModule.service.requestUrl(source, '$base/api');
    await fetchModule.service.requestUrl(source, '$base/api');
    sw.stop();
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(150));
  });

  test('fetchContent 按 nextContentUrl 串行追页并去重防环', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/p/1',
      // 下一章与分页无关，不应影响追页。
      nextChapterUrl: '$base/ch/9',
    );
    expect(fetched.html, contains('分页A'));
    expect(fetched.html, contains('分页B'));
    // /p/2 的下一页仍指向自己，必须去重停下，不能无限循环。
    expect(fetched.html.split('分页B').length, 2);
  });

  test('fetchContent 把正文内联图片绝对化，同时保留在 HTML 中', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/img',
    );

    expect(fetched.images, contains('$base/static/a.jpg'));
    expect(fetched.images, contains('$base/static/b.png'));
    // 内联图不能被剔除，否则文字章会丢图；相对 src 要换成绝对地址。
    expect(fetched.html, contains('src="$base/static/a.jpg"'));
    expect(fetched.html, contains('图前'));
    expect(fetched.html, contains('图后'));
  });

  test('fetchContent 出口应用替换净化规则', () async {
    await addContentSource('a.next@href');
    // 正文里统一出现的词被规则替换掉，证明净化接在了抓取出口。
    store.daos.replaceRule.insert(
      ReplaceRule(
        name: '正文净化',
        pattern: '正文',
        replacement: '正文（净化）',
        isRegex: false,
      ),
    );
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/ch/1',
    );
    expect(fetched.html, contains('正文（净化）一'));
  });

  test('fetchContent 按 nextContentUrl 多链接并发抓页', () async {
    await addContentSource('a.next@href');
    final source = fetchModule.service.sourceByUrl(base)!;
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/m/1',
    );
    expect(fetched.html, contains('主文'));
    expect(fetched.html, contains('并发二'));
    expect(fetched.html, contains('并发三'));
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
    final fetched = await fetchModule.service.fetchContent(
      source,
      '$base/book/1',
      '$base/p/1',
      nextChapterUrl: '$base/p/2',
    );
    expect(fetched.html, contains('分页A'));
    expect(fetched.html, isNot(contains('分页B')));
  });

  test('ChangeSource：换源重建目录、保留分组与进度、清旧缓存', () async {
    final srcB = await addSource(
      bookSourceUrl: '$base/b2',
      searchPath: '/search2',
      name: '源乙',
    );

    // 旧书挂在源甲（bookSourceUrl = base）上，读在第 2 章。
    store.daos.book.insert(
      Book(
        bookUrl: '$base/book/1',
        name: '旧名',
        author: '旧作者',
        origin: base,
        originName: '测试源',
        type: BookType.text,
        group: 2,
        totalChapterNum: 2,
        durChapterIndex: 1,
        durChapterTitle: '第二章 后来',
      ),
    );
    final oldId = store.daos.book.idOf('$base/book/1')!;
    store.daos.chapter.insertAll([
      BookChapter(
        url: '$base/ch/1',
        bookUrl: '$base/book/1',
        index: 0,
        title: '第一章 开始',
      ),
      BookChapter(
        url: '$base/ch/2',
        bookUrl: '$base/book/1',
        index: 1,
        title: '第二章 后来',
      ),
    ]);
    store.daos.readingProgress.put(
      ReadingProgress(
        bookUrl: '$base/book/1',
        chapterIndex: 1,
        chapterTitle: '第二章 后来',
        chapterPos: 88,
        scrollPercent: 40,
        updatedAt: 1,
      ),
    );
    store.daos.cache.put('chapter_$oldId', '旧缓存');

    final result =
        await call('Source.ChangeSource', [oldId, srcB, '$base/book/2'])
            as Map<String, Object?>;
    final newId = result['bookId'] as int;
    expect(result['oldBookId'], oldId);
    // 实现是「删旧行 → 插新行」，rowid 可能被 SQLite 复用（旧行是最大 rowid 时），
    // 所以只能比较 bookUrl，不能假设 id 一定变了。
    expect(store.daos.book.getById(newId)!.bookUrl, '$base/book/2');

    final book = store.daos.book.getById(newId)!;
    expect(book.bookUrl, '$base/book/2');
    expect(book.origin, '$base/b2');
    expect(book.originName, '源乙');
    expect(book.name, '换源书名');
    expect(book.author, '换源作者');
    expect(book.intro, '换源简介');
    expect(book.group, 2, reason: '分组是用户数据，换源不能丢');
    expect(book.totalChapterNum, 3);
    expect(book.latestChapterTitle, '第三章 新结局');

    // 进度按章节序号搬过去（新源章节更多，序号 1 仍有效）
    expect(book.durChapterIndex, 1);
    expect(book.durChapterTitle, '第二章 新后来');
    final progress = store.daos.readingProgress.get('$base/book/2')!;
    expect(progress.chapterIndex, 1);
    expect(progress.chapterPos, 88, reason: '章内偏移不随源变化');
    expect(progress.scrollPercent, 40);

    // 旧书、旧章节、旧缓存都被清掉
    expect(store.daos.book.idOf('$base/book/1'), isNull);
    expect(store.daos.chapter.getChapterList('$base/book/1'), isEmpty);
    expect(store.daos.cache.get('chapter_$oldId'), isNull);
    expect(
      store.daos.chapter.getChapterList('$base/book/2').map((c) => c.title),
      ['第一章 新开始', '第二章 新后来', '第三章 新结局'],
    );
  });

  test('ChangeSource：本地书、目标已占用、同源同地址各自短路或报错', () async {
    final srcA = await addSource();
    final srcB = await addSource(
      bookSourceUrl: '$base/b2',
      searchPath: '/search2',
      name: '源乙',
    );

    store.daos.book.insert(
      Book(
        bookUrl: '${home.path}/local.txt',
        name: '本地书',
        origin: BookType.localTag,
        type: BookType.local | BookType.text,
      ),
    );
    final localId = store.daos.book.idOf('${home.path}/local.txt')!;
    await expectLater(
      call('Source.ChangeSource', [localId, srcB, '$base/book/2']),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.invalid)
            .having((e) => e.message, 'message', contains('本地书不支持换源')),
      ),
    );

    // 目标地址已被另一本书占着：换过去会顶掉别人的书，直接拒绝。
    store.daos.book.insert(
      Book(
        bookUrl: '$base/book/1',
        name: '甲书',
        origin: base,
        type: BookType.text,
      ),
    );
    final bookId = store.daos.book.idOf('$base/book/1')!;
    store.daos.book.insert(
      Book(
        bookUrl: '$base/book/2',
        name: '乙书',
        origin: base,
        type: BookType.text,
      ),
    );
    await expectLater(
      call('Source.ChangeSource', [bookId, srcB, '$base/book/2']),
      throwsA(
        isA<LegadoException>()
            .having((e) => e.code, 'code', ErrorCode.invalid)
            .having((e) => e.message, 'message', contains('已在书架中')),
      ),
    );

    // 同源同地址：什么都不做，直接返回原书（避免无意义的删库重插）。
    final same =
        await call('Source.ChangeSource', [bookId, srcA, '$base/book/1'])
            as Map<String, Object?>;
    expect(same['bookId'], bookId);
    expect(same.containsKey('oldBookId'), isFalse);
    expect(store.daos.book.getById(bookId)!.name, '甲书');
  });

  test('目录重复条目按 URL 去重并重排 index（否则按列表下标取章会错位）', () async {
    final id = await addSource();
    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/dup',
              '重复目录',
              '作者丙',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    final bookId = added['id'] as int;

    // 「最新章节」区块的 3、4 章与正文目录重复，去重后只留正文目录里的位置。
    final chapters = await callList('Reader.GetChapters', [bookId]);
    expect(
      chapters.map((c) => c['title']).toList(),
      ['第一章', '第二章', '第三章 尾', '第四章 尾'],
    );
    // index 必须等于列表下标：阅读器就是拿下标当序号调 Reader.GetContent 的。
    expect(chapters.map((c) => c['index']).toList(), [0, 1, 2, 3]);
    // 库里也必须连续 0..n-1（chapters 主键是 url，重复行会被 REPLACE 覆盖）。
    expect(
      store.daos.chapter
          .getChapterList('$base/book/dup')
          .map((c) => c.index)
          .toList(),
      [0, 1, 2, 3],
    );

    // 点目录第 2 项必须拿到第二章。
    final content =
        await call('Reader.GetContent', [bookId, 1]) as Map<String, Object?>;
    expect(content['title'], '第二章');
  });

  test('目录分页：nextTocUrl 的多页地址按序抓全', () async {
    final id = await addSource(ruleToc: {
      'chapterList': 'li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
      'nextTocUrl': 'a.next@href',
    });
    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/paged',
              '分页目录',
              '作者丁',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    final chapters = await callList('Reader.GetChapters', [added['id']]);

    expect(
      chapters.map((c) => c['title']).toList(),
      ['第一章', '第二章', '第三章', '第四章'],
    );
    expect(chapters.map((c) => c['index']).toList(), [0, 1, 2, 3]);
  });

  test('目录规则 `-` 前缀表示倒序，抓取后翻成阅读顺序', () async {
    final id = await addSource(ruleToc: {
      'chapterList': '-li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    });
    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/rev',
              '倒序目录',
              '作者戊',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    final chapters = await callList('Reader.GetChapters', [added['id']]);

    expect(
      chapters.map((c) => c['title']).toList(),
      ['第一章', '第二章', '第三章', '第四章'],
    );
  });

  test('bookInfo.init 求值结果替换详情页内容', () async {
    // 页面里书名/作者是自定义标签，字段规则本身命中不到；
    // 只有先跑 init 把标签换成标准结构才能解析出来。
    final initJs = r'@js:result.replace("<bookname>","<h1 class=\"bookname\">")'
        r'.replace("</bookname>","</h1>")'
        r'.replace("<author>","<span class=\"author\">")'
        r'.replace("</author>","</span>")';
    final id = await addSource(ruleBookInfo: {
      'init': initJs,
      'name': '.bookname@text',
      'author': '.author@text',
      'tocUrl': '.toc@href',
    });
    final preview =
        await call('Source.PreviewBook', [
              id,
              '$base/book/init',
              '占位书名',
              '占位作者',
              '{}',
            ])
            as Map<String, Object?>;

    expect(preview['name'], '初始化书名');
    expect(preview['author'], '初始化作者');
    expect(preview['totalChapters'], 2);
  });

  test('preUpdateJs / formatJs 生效，脚本可用 cookie、cache、java.getCookie、java.connect', () async {
    final id = await addSource(ruleToc: {
      'preUpdateJs': r'java.put("tag","脚本");'
          r'cookie.setCookie(baseUrl,"sid=42");'
          r'cache.put("c","缓存");'
          r'cache.put("api", java.connect(baseUrl + "/api").body())',
      'chapterList': 'li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
      'formatJs': r'title + "|" + index + "|" + cookie.getKey(baseUrl,"sid")'
          r' + "|" + cache.get("c") + "|" + java.getCookie(baseUrl) + "|" + tag'
          r' + "|" + cache.get("api")',
    });
    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/1',
              '脚本测试',
              '作者',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    final chapters = await callList('Reader.GetChapters', [added['id']]);

    // preUpdateJs 写入的 java 变量在后续规则里可见（tag），
    // cookie / cache / java.getCookie / java.connect(...).body() 都能用。
    expect(chapters.first['title'], '第一章 开始|1|42|缓存|sid=42|脚本|{"api":1}');
    expect(chapters[1]['title'], '第二章 后来|2|42|缓存|sid=42|脚本|{"api":1}');
  });

  test('书源变量（Source.SetVariable）在抓取规则里可读', () async {
    final id = await addSource(ruleToc: {
      'chapterList': 'li',
      'chapterName': '{{tag}}',
      'chapterUrl': 'a@href',
    });
    await call('Source.SetVariable', [id, '{"tag":"变量标题"}']);

    final added =
        await call('Source.AddToShelf', [
              id,
              '$base/book/1',
              '变量测试',
              '作者',
              '{}',
              0,
            ])
            as Map<String, Object?>;
    final chapters = await callList('Reader.GetChapters', [added['id']]);

    expect(chapters.first['title'], '变量标题');
  });

  test('历史数据 index 有空洞时 Reader.GetChapters 自愈重排', () async {
    final id = await addSource();
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
    final bookId = added['id'] as int;

    // 手工制造空洞：把最后一章的 index 改大（模拟重复 URL 被 REPLACE 后的残留）。
    final rows = store.daos.chapter.getChapterList('$base/book/1');
    store.daos.chapter.update(rows.last..index = 9);
    expect(
      store.daos.chapter.getChapterList('$base/book/1').map((c) => c.index),
      [0, 9],
    );

    final chapters = await callList('Reader.GetChapters', [bookId]);
    expect(chapters.map((c) => c['index']).toList(), [0, 1]);
    expect(
      store.daos.chapter.getChapterList('$base/book/1').map((c) => c.index),
      [0, 1],
    );
  });

  test('loginCheckJs 改写响应体：赋值 result.body / 直接返回字符串', () async {
    // 1. 脚本改 `result.body`（原版最常见的写法）。
    final srcA = await addSource(
      name: '登录检测A',
      loginCheckJs: "result.body = result.body.replace('搜索书名', '登录后书名');",
    );
    final a = await callList('Source.Search', [srcA, '关键词', 1]);
    expect(a.map((r) => r['name']), contains('登录后书名'));
    expect(a.map((r) => r['name']), isNot(contains('搜索书名')));

    // 2. 脚本直接 return 新正文。
    final srcB = await addSource(
      name: '登录检测B',
      loginCheckJs: "result.body.replace('另一本', '改名书')",
    );
    final b = await callList('Source.Search', [srcB, '关键词', 1]);
    expect(b.map((r) => r['name']), contains('改名书'));

    // 3. 脚本抛错不能打断链路：按原响应继续解析。
    final srcC = await addSource(
      name: '登录检测C',
      loginCheckJs: 'this_is_not_defined();',
    );
    final c = await callList('Source.Search', [srcC, '关键词', 1]);
    expect(c, isNotEmpty);
  });
}
