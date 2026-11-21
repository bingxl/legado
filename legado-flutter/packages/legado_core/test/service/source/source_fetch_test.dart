import 'dart:convert';
import 'dart:io';

import 'package:legado_core/src/domain/domain.dart';
import 'package:legado_core/src/kernel/errors.dart';
import 'package:legado_core/src/kernel/module.dart';
import 'package:legado_core/src/kernel/registry.dart';
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
    Map<String, Object?>? ruleToc,
    Map<String, Object?>? ruleBookInfo,
  }) async {
    final sourceUrl = bookSourceUrl ?? base;
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': sourceUrl,
      'bookSourceName': name,
      'bookSourceGroup': '小说',
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
    });
    final view =
        await call('Source.Save', [
              0,
              name,
              '小说',
              sourceUrl,
              '',
              raw,
              true,
              0,
            ])
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
  Future<void> addContentSource(String nextRule, {String? titleRule}) async {
    final raw = jsonEncode(<String, Object?>{
      'bookSourceUrl': base,
      'bookSourceName': '正文源',
      'enabled': true,
      'ruleContent': jsonEncode({
        'content': '#content@html',
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
}
