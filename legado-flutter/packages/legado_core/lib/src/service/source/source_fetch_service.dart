import 'dart:convert';

import 'package:logging/logging.dart';

import '../../domain/domain.dart';
import '../../js/java_host.dart';
import '../../js/js_engine.dart';
import '../../js/js_engine_factory.dart';
import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../../rules/rules.dart';
import '../../store/dao/book_source_dao.dart';
import '../../store/database.dart';
import '../../store/store.dart';
import '../../util/url.dart';
import '../shelf/shelf_service.dart';

final Logger _log = Logger('legado.js');

/// 书源脚本里 `console.log` / `print` 的输出。
void _logJsMessage(String level, String msg) {
  if (level == 'warn') {
    _log.warning(msg);
  } else if (level == 'error') {
    _log.severe(msg);
  } else {
    _log.info(msg);
  }
}

/// 发现分类视图。
class ExploreKindView {
 const ExploreKindView({required this.title, required this.url, this.paged = true});

  final String title;
  final String url;
  final bool paged;

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'url': url,
        'paged': paged,
      };
}

class ExploreSourceBrief {
  const ExploreSourceBrief({
    required this.id,
    required this.name,
    required this.group,
    required this.url,
    required this.enabled,
    required this.enabledExplore,
    required this.hasExploreUrl,
    required this.hasLoginUrl,
    required this.hasSearchUrl,
  });

  final int id;
  final String name;
  final String group;
  final String url;
  final bool enabled;
  final bool enabledExplore;
  final bool hasExploreUrl;
  final bool hasLoginUrl;

  /// 是否配置了搜索地址（纯发现源为 false，UI 据此决定是否显示「搜索」入口）。
  final bool hasSearchUrl;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'group': group,
        'url': url,
        'enabled': enabled,
        'enabledExplore': enabledExplore,
        'hasExploreUrl': hasExploreUrl,
        'hasLoginUrl': hasLoginUrl,
        'hasSearchUrl': hasSearchUrl,
      };
}

/// 单源搜索/发现结果。
class SearchResultView {
 const SearchResultView({
    required this.name,
    required this.author,
    required this.cover,
    required this.intro,
    required this.bookUrl,
    required this.origin,
    required this.originName,
    required this.lastChapter,
    required this.kind,
    this.variable = '',
  });

  final String name;
  final String author;
  final String cover;
  final String intro;
  final String bookUrl;
  final String origin;
  final String originName;
  final String lastChapter;
  final String kind;
  final String variable;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'author': author,
        'cover': cover,
        'intro': intro,
        'bookUrl': bookUrl,
        'origin': origin,
        'originName': originName,
        'lastChapter': lastChapter,
        'kind': kind,
        if (variable.isNotEmpty) 'variable': variable,
      };
}

/// 书源抓取链路：搜索 / 发现 / 详情 / 目录 / 试读入库。
///
/// 一条规则的执行顺序是「URL 规则展开 → HTTP → AnalyzeRule 取值」，
/// 三件事分别交给 `UrlRuleAnalyzer`、`NetClient`、`AnalyzeRule`，
/// 这一层只负责串起来与落库，不再写第四份规则解析。
class SourceFetchService {
  SourceFetchService({
    required StoreDaos daos,
    required ShelfService shelf,
  })  : _daos = daos,
        _shelf = shelf,
        _net = NetClient(),
        _js = createJsEngine(onLog: _logJsMessage);

  final StoreDaos _daos;
  final ShelfService _shelf;
  final NetClient _net;
  final JsEngine _js;

  void close() {
    _net.close();
    _js.dispose();
  }

  // ---- 发现 -----------------------------------------------------------

  List<ExploreSourceBrief> listExploreSources() {
    final out = <ExploreSourceBrief>[];
    for (final source in _daos.bookSource.all) {
      if (!source.enabled || !source.enabledExplore) continue;
      if ((source.exploreUrl ?? '').trim().isEmpty) continue;
      final id = _dao.rowIdOf(source.bookSourceUrl) ?? 0;
      out.add(ExploreSourceBrief(
        id: id,
        name: source.bookSourceName,
        group: source.bookSourceGroup ?? '',
        url: source.bookSourceUrl,
        enabled: source.enabled,
        enabledExplore: source.enabledExplore,
        hasExploreUrl: true,
        hasLoginUrl: (source.loginUrl ?? '').trim().isNotEmpty,
        hasSearchUrl: (source.searchUrl ?? '').trim().isNotEmpty,
      ));
    }
    return out;
  }

  /// 纯本地解析 `exploreUrl`：JS 脚本 / JSON 数组 / `标题::URL&&...` / 单 URL。
  ///
  /// 对齐 Kotlin `BookSourceExtensions.exploreKinds` 与 Go
  /// `webbook.GetExploreKinds`：`exploreUrl` 为 `<js>...</js>` 或 `@js:...`
  /// 时必须**先执行脚本**，拿脚本输出的字符串再按 `&&` / 换行切分类。
  /// 超星等书源的分类地址由脚本动态拼出（含 channelId、分页参数与内嵌
  /// JSON 选项），直接把脚本文本当 URL 切会得到一堆伪分类。
  Future<List<ExploreKindView>> exploreKinds(int sourceId) async {
    final source = _requireSource(sourceId);
    var raw = (source.exploreUrl ?? '').trim();
    if (raw.isEmpty) return const [];

    // JS 形态：截出脚本正文并执行，结果（可能是 JSON 数组或 `标题::URL&&...`
    // 文本）覆盖 raw，继续走下面的通用解析。
    final lower = raw.toLowerCase();
    if (lower.startsWith('<js>') || lower.startsWith('@js:')) {
      final String code;
      if (lower.startsWith('@js:')) {
        code = raw.substring(4);
      } else {
        // 容错：`</js>` 缺失也不崩（对齐 Go webbook.exploreKindsJS）。
        final close = RegExp(r'</js>\s*$', caseSensitive: false).firstMatch(raw);
        code = raw.substring(4, close?.start ?? raw.length);
      }
      String text;
      try {
        // 用 _contextOf 共享 java/source/@put 等绑定（对齐 Kotlin runScriptWithContext）。
        final value = await _contextOf(source).evalJs(code, null);
        text = (value?.toString() ?? '').trim();
      } on Object catch (e) {
        // 不让脚本文本冒充分类；按 Kotlin 约定塞 ERROR 分类供 UI 展示。
        _log.warning('发现分类 JS 执行失败: $e');
        return [ExploreKindView(title: 'ERROR:$e', url: e.toString())];
      }
      if (text.isEmpty) return const [];
      raw = text;
    }

    if (raw.startsWith('[') || raw.startsWith('{')) {
      Object? decoded;
      try {
        decoded = jsonDecode(_looseJson(raw));
      } on FormatException {
        decoded = null;
      }
      if (decoded is Map && decoded['sources'] is List) {
        decoded = decoded['sources'];
      }
      if (decoded is List) {
        final out = <ExploreKindView>[];
        for (final item in decoded) {
          if (item is! Map) continue;
          final title = '${item['title'] ?? item['name'] ?? ''}'.trim();
          final url = '${item['url'] ?? ''}'.trim();
          if (url.isEmpty) continue;
          out.add(ExploreKindView(
            title: title.isEmpty ? '全部' : title,
            url: url,
            paged: item['paged'] == null ? true : _flag(item['paged']),
          ));
        }
        return out;
      }
    }
    // 多行分类：原版按 `(&&|\n)+` 切分，每行按 `::` 切成 [标题, URL]。
    //
    // 真实书源的 exploreUrl 几乎都是这个格式，例如：
    //   冒险::/data/sort,{"method":"POST","body":"s=1&p={{page}}"}
    //   热血::/data/sort,{"method":"POST","body":"s=2&p={{page}}"}
    final segments = raw
        .split(RegExp(r'(&&|\n)+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (segments.length > 1) {
      final out = <ExploreKindView>[];
      for (final seg in segments) {
        final cfg = seg.split('::');
        final title = cfg.first.trim();
        final url = cfg.length > 1 ? cfg.sublist(1).join('::').trim() : '';
        if (url.isEmpty) continue;
        out.add(ExploreKindView(
          title: title.isEmpty ? '全部' : title,
          url: url,
          paged: true,
        ));
      }
      if (out.isNotEmpty) return out;
    }

    // `标题,URL` 或纯 URL；形如 `最新,https://...` 也接受中文逗号。
    final parts = raw.split(RegExp(r'[,，]'));
    if (parts.length >= 2 && parts.first.trim().isNotEmpty) {
      final url = parts.sublist(1).join(',').trim();
      if (url.isNotEmpty) {
        return [ExploreKindView(title: parts.first.trim(), url: url)];
      }
    }
    return [ExploreKindView(title: '全部', url: raw)];
  }

  Future<List<SearchResultView>> explore(int sourceId, String url, int page) async {
    final source = _requireSource(sourceId);
    var target = url.trim();
    if (target.isEmpty) {
      final kinds = await exploreKinds(sourceId);
      if (kinds.isEmpty) {
        throw const LegadoException(ErrorCode.invalid, '书源没有配置发现分类');
      }
      target = kinds.first.url;
    }
    return _searchByUrl(source, target, '', page < 1 ? 1 : page, useExploreRule: true);
  }

  // ---- 搜索 -----------------------------------------------------------

  Future<List<SearchResultView>> search(
    int sourceId,
    String keyword,
    int page,
  ) async {
    if (keyword.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '搜索关键词不能为空');
    }
    final source = _requireSource(sourceId);
    final searchUrl = (source.searchUrl ?? '').trim();
    if (searchUrl.isEmpty) {
      throw LegadoException(
        ErrorCode.invalid,
        '书源 ${source.bookSourceName} 没有配置搜索地址',
      );
    }
    return _searchByUrl(source, searchUrl, keyword.trim(), page < 1 ? 1 : page);
  }

  Future<List<SearchResultView>> searchAll(String keyword, int page) async {
    final sources = _daos.bookSource.all.where((source) => source.enabled).toList();
    final out = <SearchResultView>[];
    for (final source in sources) {
      try {
        out.addAll(await search(_sourceRowId(source.bookSourceUrl), keyword, page));
      } on Object {
        // 单源失败不影响其它源的结果，与 Go 版一致。
      }
    }
    return out;
  }

  Future<List<SearchResultView>> _searchByUrl(
    BookSource source,
    String ruleUrl,
    String keyword,
    int page, {
    bool useExploreRule = false,
  }) async {
    final context = _contextOf(source);
    final analyzer = UrlRuleAnalyzer(context, key: keyword, page: page);
    final analyzed = await analyzer.analyze(ruleUrl, baseUrl: source.bookSourceUrl);
    final response = await _request(
      analyzed,
      extraHeaders: _sourceHeaders(source),
    );
    final body = response.text();
    final analyze = AnalyzeRule(_contextOf(source, baseUrl: response.finalUri.toString()));

    Map<String, Object?> ruleMap;
    try {
      final raw = useExploreRule
          ? (source.ruleExplore ?? source.ruleSearch ?? '{}')
          : (source.ruleSearch ?? '{}');
      final decoded = jsonDecode(_looseJson(raw.isEmpty ? '{}' : raw));
      ruleMap = decoded is Map ? decoded.cast<String, Object?>() : <String, Object>{};
    } on FormatException {
      ruleMap = <String, Object>{};
    }
    final rule = SearchRule.fromJson(ruleMap);
    final items = await analyze.getElements(rule.bookList, body);
    final out = <SearchResultView>[];
    for (var i = 0; i < items.length; i++) {
      final element = items[i];
      final name = await _first(analyze, rule.name, element);
      final bookUrl = await _first(analyze, rule.bookUrl, element, isUrl: true);
      if (bookUrl.isEmpty) continue;
      final variables = <String, String>{...context.variables};
      out.add(SearchResultView(
        name: name.isEmpty ? '未命名' : name,
        author: await _first(analyze, rule.author, element),
        cover: await _first(analyze, rule.coverUrl, element, isUrl: true),
        intro: await _first(analyze, rule.intro, element),
        bookUrl: bookUrl,
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        lastChapter: await _first(analyze, rule.lastChapter, element),
        kind: await _first(analyze, rule.kind, element),
        variable: jsonEncode(variables),
      ));
    }
    return out;
  }

  // ---- 试读 / 入架 ----------------------------------------------------

  /// [inShelf] 为 false 时写入 `BookType.notShelf` 位，书架列表看不到。
  Future<Map<String, Object?>> upsertBook(
    int sourceId,
    String bookUrl,
    String name,
    String author,
    String variable,
    int groupId,
    bool inShelf, [
    String fallbackCover = '',
  ]) async {
    final source = _requireSource(sourceId);
    final trimmedUrl = bookUrl.trim();
    if (trimmedUrl.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '缺少书籍地址');
    }
    final existing = _daos.book.getByUrl(trimmedUrl);
    if (existing != null) {
      var changed = false;
      if (inShelf && existing.type & BookType.notShelf != 0) {
        existing.type &= ~BookType.notShelf;
        changed = true;
      }
      // 老书/试读态可能没有封面（书源的 ruleBookInfo.coverUrl 为空是常态），
      // 搜索/发现结果里的 cover 是现成的，补上即可，不必重新抓详情。
      if ((existing.coverUrl?.trim().isEmpty ?? true) &&
          fallbackCover.isNotEmpty) {
        existing.coverUrl = fallbackCover;
        changed = true;
      }
      if (changed) _daos.book.update(existing);
      return _shelf.brief(_rowId(trimmedUrl), existing);
    }

    final variables = _decodeVariables(variable);
    final bookContext = _contextOf(source, variables: variables);
    final info = await _fetchInfo(
      bookContext,
      source,
      trimmedUrl,
      name,
      author,
      fallbackCover,
    );

    // 先构造 Book 再抓目录：`ruleToc` 的 JS 里常写 `book.bookUrl`，
    // 原版 AnalyzeRule 在解析目录时也注入了 `book` 绑定。
    final book = Book(
      bookUrl: trimmedUrl,
      tocUrl: info.$2,
      origin: source.bookSourceUrl,
      originName: source.bookSourceName,
      name: info.$1.name,
      author: info.$1.author,
      kind: info.$1.kind,
      intro: info.$1.intro,
      coverUrl: info.$1.cover,
      latestChapterTitle: info.$1.lastChapter,
      type: _typeOf(source.bookSourceType) |
          (inShelf ? 0 : BookType.notShelf),
      group: groupId > 0 ? groupId : 0,
      variable: variable.isEmpty ? null : variable,
    );

    final chapters = await _fetchToc(
      _contextOf(source, variables: variables, extra: {'book': book.toRow()}),
      source,
      info.$2,
      trimmedUrl,
    );

    book.totalChapterNum = chapters.length;
    book.lastCheckTime = DateTime.now().millisecondsSinceEpoch;

    runInTransaction(_daos.db, () {
      _daos.book.insert(book);
      for (final chapter in chapters) {
        _daos.chapter.insert(chapter);
      }
    });
    return _shelf.brief(_rowId(trimmedUrl), book);
  }

  /// 按书籍详情页 URL 加书（对齐 Kotlin `BookshelfViewModel.addBookByUrl`）。
  ///
  /// 支持多行 URL。每行：已存在则跳过 → 取域名精确匹配书源 → 无果再用
  /// `bookUrlPattern` 正则匹配 → 命中后走 [upsertBook] 解析详情/目录并入库。
  /// 返回 `{success: [{url, book}], failed: [{url, reason}]}`。
  Future<Map<String, Object?>> addBookByUrl(
    String urls,
    int groupID,
  ) async {
    final success = <Map<String, Object?>>[];
    final failed = <Map<String, Object?>>[];
    for (final rawLine in urls.split(RegExp(r'\r?\n'))) {
      final url = rawLine.trim();
      if (url.isEmpty) continue;
      try {
        if (_daos.book.getByUrl(url) != null) {
          failed.add(<String, Object?>{'url': url, 'reason': '书籍已存在'});
          continue;
        }
        final source = _matchSourceForBookUrl(url);
        if (source == null) {
          throw const LegadoException(
            ErrorCode.notFound,
            '未找到匹配书源',
          );
        }
        final sourceId = _daos.bookSource.rowIdOf(source.bookSourceUrl);
        if (sourceId == null) {
          throw const LegadoException(ErrorCode.invalid, '书源 ID 缺失');
        }
        // name/author 传空，交给书源的 ruleBookInfo 从详情页解析。
        final brief = await upsertBook(sourceId, url, '', '', '', groupID, true);
        success.add(<String, Object?>{'url': url, 'book': brief});
      } on LegadoException catch (e) {
        failed.add(<String, Object?>{'url': url, 'reason': e.message});
      } on Object catch (e) {
        failed.add(<String, Object?>{'url': url, 'reason': '$e'});
      }
    }
    return <String, Object?>{'success': success, 'failed': failed};
  }

  /// 为详情页 URL 匹配书源：先域名精确匹配，再 bookUrlPattern 正则。
  BookSource? _matchSourceForBookUrl(String bookUrl) {
    final baseUrl = getBaseUrl(bookUrl);
    if (baseUrl != null && baseUrl.isNotEmpty) {
      final exact = _daos.bookSource.getBookSourceAddBook(baseUrl);
      if (exact != null) return exact;
    }
    for (final source in _daos.bookSource.hasBookUrlPattern()) {
      final pattern = source.bookUrlPattern;
      if (pattern == null || pattern.trim().isEmpty || pattern == 'NONE') continue;
      try {
        if (RegExp(pattern).hasMatch(bookUrl)) return source;
      } on Object {
        // 非法正则跳过，避免一条坏规则连累整次加书。
      }
    }
    return null;
  }

  /// 拉详情：返回 `(元信息, 目录地址)`。
  Future<(_BookMeta, String)> _fetchInfo(
    RuleContext context,
    BookSource source,
    String bookUrl,
    String fallbackName,
    String fallbackAuthor, [
    String fallbackCover = '',
  ]) async {
    final headers = _sourceHeaders(source);
    final client = headers.isEmpty ? _net : _net.withHeaders(headers);
    final response = await client.get(Uri.parse(bookUrl));
    if (!response.isSuccess) {
      throw LegadoException(
        ErrorCode.netTimeout,
        '获取详情失败: HTTP ${response.statusCode}',
      );
    }
    final body = response.text();
    final analyze = AnalyzeRule(
      _contextOf(source,
          baseUrl: response.finalUri.toString(),
          variables: context.variables,
          extra: context.extraBindings),
    );
    var ruleMap = <String, Object?>{};
    try {
      final decoded = jsonDecode(_looseJson(source.ruleBookInfo ?? '{}'));
      if (decoded is Map) ruleMap = decoded.cast<String, Object?>();
    } on FormatException {
      // 规则为空时保留搜索页已填的字段。
    }
    final rule = BookInfoRule.fromJson(ruleMap);
    Future<String> pick(String? r, [String fallback = '']) async {
      final value = await analyze.getString(r, body);
      return value.isEmpty ? fallback : value;
    }

    final parsedCover = await analyze.getString(rule.coverUrl, body, true);
    final meta = _BookMeta(
      name: await pick(rule.name, fallbackName),
      author: await pick(rule.author, fallbackAuthor),
      intro: await pick(rule.intro),
      kind: await pick(rule.kind),
      cover: _withFallbackCover(
        // getString(isUrl:true) 在规则解出空串时会回落到 baseUrl（对 tocUrl
        // 合理，对封面却是「把详情页当图片」），这里显式挡掉。
        parsedCover == response.finalUri.toString() ? '' : parsedCover,
        fallbackCover,
      ),
      lastChapter: await pick(rule.lastChapter),
    );
    if (meta.name.trim().isEmpty) {
      throw const LegadoException(
        ErrorCode.invalid,
        '书源详情页没有解析出书名，请检查书名规则',
      );
    }
    final tocUrl = await analyze.getString(rule.tocUrl, body, true);
    return (meta, tocUrl.isEmpty ? bookUrl : tocUrl);
  }

  Future<List<BookChapter>> _fetchToc(
    RuleContext context,
    BookSource source,
    String tocUrl,
    String bookUrl,
  ) async {
    final headers = _sourceHeaders(source);
    final client = headers.isEmpty ? _net : _net.withHeaders(headers);
    final response = await client.get(Uri.parse(tocUrl));
    if (!response.isSuccess) {
      throw LegadoException(
        ErrorCode.netTimeout,
        '获取目录失败: HTTP ${response.statusCode}',
      );
    }
    final body = response.text();
    final analyze = AnalyzeRule(
      _contextOf(source,
          baseUrl: response.finalUri.toString(),
          variables: context.variables,
          // 保留调用方传进来的绑定（`book` 等），
          // 书源的 ruleToc 常写 `book.bookUrl`。
          extra: context.extraBindings),
    );
    var ruleMap = <String, Object?>{};
    try {
      final decoded = jsonDecode(_looseJson(source.ruleToc ?? '{}'));
      if (decoded is Map) ruleMap = decoded.cast<String, Object?>();
    } on FormatException {
      // 目录规则缺失时返回空目录，交给调用方报错。
    }
    final rule = TocRule.fromJson(ruleMap);
    final items = await analyze.getElements(rule.chapterList, body);
    final out = <BookChapter>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final title = await _first(analyze, rule.chapterName, item);
      final url = await _first(analyze, rule.chapterUrl, item, isUrl: true);
      if (url.isEmpty) continue;
      out.add(BookChapter(
        url: url,
        bookUrl: bookUrl,
        index: out.length,
        title: title.isEmpty ? '第 ${out.length + 1} 章' : title,
        isVolume: _flag(await _first(analyze, rule.isVolume, item)),
        isVip: _flag(await _first(analyze, rule.isVip, item)),
        isPay: _flag(await _first(analyze, rule.isPay, item)),
      ));
    }
    if (out.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书源目录没有解析出章节');
    }
    return out;
  }

  /// 按书源地址取书源实体（网络书正文抓取要靠它找规则）。
  BookSource? sourceByUrl(String url) {
    for (final source in _daos.bookSource.all) {
      if (source.bookSourceUrl == url) return source;
    }
    return null;
  }

  /// 抓网络书正文（含 `ruleContent.nextContentUrl` 多页翻页）。
  ///
  /// 返回 `(正文HTML, 图片直链列表)`。
  ///
  /// [bookUrl] 是书籍地址（用来定位书源与拼相对地址），[chapterUrl] 是章节地址。
  /// [nextChapterUrl] 是下一章地址，既作为脚本里的 `nextChapterUrl` 绑定，
  /// 也用于阻止翻页时误翻到下一章（对齐 Kotlin `BookContent.analyzeContent`）。
  ///
  /// 翻页语义照抄原版 `BookContent.analyzeContent`：
  /// - 解出 1 个下一页链接 → 串行抓，直到链接为空 / 已访问过 / 指向下一章；
  /// - 解出多个链接 → 并发抓（图片书分页常见），结果拼到正文末尾。
  Future<(String, List<String>)> fetchContent(
    BookSource source,
    String bookUrl,
    String chapterUrl, {
    String? nextChapterUrl,
  }) async {
    var ruleMap = <String, Object?>{};
    try {
      final decoded = jsonDecode(_looseJson(source.ruleContent ?? '{}'));
      if (decoded is Map) ruleMap = decoded.cast<String, Object?>();
    } on FormatException {
      // 正文规则缺失时报错，见下。
    }
    if (ruleMap.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书源缺少正文规则');
    }
    final rule = ContentRule.fromJson(ruleMap);

    final headers = _sourceHeaders(source);
    final absolute = getAbsoluteUrl(
      getBaseUrl(bookUrl) ?? source.bookSourceUrl,
      chapterUrl,
    );

    /// 抓并解析一页。
    ///
    /// 走 [UrlRuleAnalyzer] + [_request] 而不是裸 GET，让下一页链接里的
    /// `url,{"method":"POST","body":"..."}` 写法真正生效（对齐原版 AnalyzeUrl）。
    Future<({String content, List<String> images, List<String> nextUrls, String finalUrl})>
        loadPage(String fetchUrl, String baseForFetch) async {
      final analyzer = UrlRuleAnalyzer(
        _contextOf(source, baseUrl: baseForFetch),
      );
      final analyzed = await analyzer.analyze(fetchUrl, baseUrl: baseForFetch);
      final response = await _request(analyzed, extraHeaders: headers);
      if (!response.isSuccess) {
        throw LegadoException(
          ErrorCode.netTimeout,
          '获取正文失败: HTTP ${response.statusCode}',
        );
      }
      final body = response.text();
      // 用响应后的最终地址作 base：重定向站点里相对图片/相对下一页链接才拼得对。
      final redirectUrl = response.finalUri.toString();
      final analyze = AnalyzeRule(
        _contextOf(
          source,
          baseUrl: redirectUrl,
          extra: {
            'book': <String, Object?>{'bookUrl': bookUrl},
            'chapter': <String, Object?>{'url': chapterUrl},
            'title': '',
            'src': body,
            // 书源规则里 `{{nextChapterUrl}}` 常用来避开把“下一章”当成本章下一页。
            'nextChapterUrl': nextChapterUrl,
          },
        ),
      );

      var content = await analyze.getString(rule.content, body);

      // 图片直链 + 正文内联图片：
      // 漫画章用 images 列表整页渲染；文字章的图片必须留在正文里按位置显示。
      // 书源作者常写 data-src / specialdata-src（懒加载），这里一并识别并
      // 把 src 改写成绝对地址，UI 就不用猜相对路径的基准。
      final images = <String>[];
      final imgTagRe = RegExp(r'<img\b[^>]*>', caseSensitive: false);
      final imgAttrRe = RegExp(
        r'''(?:src|data-src|specialdata-src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
        caseSensitive: false,
      );
      content = content.replaceAllMapped(imgTagRe, (match) {
        final tag = match.group(0) ?? '';
        String? raw;
        for (final attr in imgAttrRe.allMatches(tag)) {
          final value = attr.group(1) ?? attr.group(2) ?? attr.group(3) ?? '';
          if (value.trim().isNotEmpty) {
            raw = value.trim();
            break;
          }
        }
        if (raw == null) return tag;
        final absolute = getAbsoluteUrl(redirectUrl, raw);
        if (absolute.isEmpty) return tag;
        images.add(absolute);
        // 去掉各种懒加载属性，只留一个绝对 src，避免 UI 取到占位图。
        final normalized = tag.replaceAll(imgAttrRe, '');
        return normalized.replaceFirst(
          RegExp(r'<img', caseSensitive: false),
          '<img src="$absolute"',
        );
      });

      // 下一页链接（isUrl=true：相对地址绝对化 + 去重），这就是 nextContentUrl。
      final nextUrls = <String>[];
      final nextRule = rule.nextContentUrl;
      if (nextRule != null && nextRule.isNotEmpty) {
        nextUrls.addAll(await analyze.getStringList(nextRule, body, true));
      }
      return (
        content: content,
        images: images,
        nextUrls: nextUrls,
        finalUrl: redirectUrl,
      );
    }

    // ---- 首页 ----
    final first = await loadPage(chapterUrl, absolute);
    final pages = <String>[first.content];
    final allImages = <String>[...first.images];
    // 首页最终地址，作为下一页链接的相对基准与防重复种子。
    final firstFinalUrl = first.finalUrl;

    // 已访问页：以首页最终地址为种子，避免 nextContentUrl 指回首页时死循环。
    final visited = <String>{firstFinalUrl};
    final nextChapterAbs = (nextChapterUrl == null || nextChapterUrl.isEmpty)
        ? null
        : getAbsoluteUrl(firstFinalUrl, nextChapterUrl);

    final nextUrls = first.nextUrls;
    if (nextUrls.length == 1) {
      // 单链接：串行追页，直到为空 / 回到已访问页 / 指向下一章。
      var nextUrl = nextUrls.first;
      while (nextUrl.isNotEmpty && !visited.contains(nextUrl)) {
        if (nextChapterAbs != null && nextUrl == nextChapterAbs) break;
        visited.add(nextUrl);
        final page = await loadPage(nextUrl, firstFinalUrl);
        pages.add(page.content);
        allImages.addAll(page.images);
        // nextContentUrl 是相对地址时，以「当前页」为基准拼下一页
        // （getStringList 已在 loadPage 里用该页 finalUrl 绝对化，这里只是推进链接）。
        nextUrl = page.nextUrls.isEmpty ? '' : page.nextUrls.first;
      }
    } else if (nextUrls.length > 1) {
      // 多链接：并发抓（原版 flow + mapAsync），按规则顺序拼接。
      final targets = <String>[];
      for (final url in nextUrls) {
        if (url.isEmpty || visited.contains(url) || url == nextChapterAbs) continue;
        visited.add(url);
        targets.add(url);
      }
      if (targets.isNotEmpty) {
        const concurrency = 8;
        for (var start = 0; start < targets.length; start += concurrency) {
          final batch = targets.skip(start).take(concurrency).toList();
          final results = await Future.wait(
            batch.map((url) => loadPage(url, firstFinalUrl)),
          );
          for (final page in results) {
            pages.add(page.content);
            allImages.addAll(page.images);
          }
        }
      }
    }

    final contentStr = pages.join('\n');
    if (contentStr.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书源正文规则没有解析出内容');
    }
    return (contentStr, allImages);
  }

  // ---- helpers --------------------------------------------------------

  BookSourceDao get _dao => _daos.bookSource;

  BookSource _requireSource(int id) {
    final sources = _dao.getByRowIds([id]);
    if (sources.isEmpty) {
      throw LegadoException(ErrorCode.notFound, '书源不存在: $id');
    }
    return sources.first;
  }

  /// 书源表里某书源的 rowid（书源的对外整数 ID）。
  int _sourceRowId(String url) => _dao.rowIdOf(url) ?? 0;

  /// 书籍的对外整数 ID（SQLite rowid）。
  ///
  /// 注意别用错 DAO：`_dao` 是书源表，`_daos.book` 才是书表。
  /// 之前这里错用了书源表的 `rowIdOf`，拿 bookUrl 去查书源表永远查不到，
  /// 试读书的 bookId 恒为 0，导致目录/正文全部取不到。
  int _rowId(String url) => _daos.book.idOf(url) ?? 0;

  int _typeOf(int sourceType) => switch (sourceType) {
        BookSourceType.audio => BookType.audio,
        BookSourceType.image => BookType.image,
        BookSourceType.file => BookType.webFile,
        _ => BookType.text,
      };

  SimpleRuleContext _contextOf(
    BookSource source, {
    String baseUrl = '',
    Map<String, String>? variables,
    Map<String, Object?> extra = const {},
    bool withJava = true,
  }) =>
      SimpleRuleContext(
        js: _js,
        baseUrl: baseUrl.isEmpty ? source.bookSourceUrl : baseUrl,
        variables: variables ?? <String, String>{},
        source: source.toJson(),
        // `_javaHost` 内部会再构造上下文（给 java.getString 回调用），
        // 那层不能再带 java，否则无限递归。
        javaHost: withJava
            ? _javaHost(source, baseUrl: baseUrl, variables: variables)
            : null,
        extraBindings: extra,
      );

  /// 构造书源脚本里的 `java` 宿主对象。
  ///
  /// 与 Kotlin 侧 `AnalyzeRule` 的 `java` 对象对齐：纯计算能力（base64/md5/hex/
  /// 编码/时间）由 `createJavaObject` 提供；`ajax`/`get`/`post` 走网络层；
  /// `getString`/`getList`/`getElements` 回到规则层自身解析。
  ///
  /// 不注入的话，书源规则里的 `java.encodeURI(...)` 会直接抛
  /// `ReferenceError: "java" 未定义`，整条规则作废。
  Object _javaHost(
    BookSource source, {
    String baseUrl = '',
    Map<String, String>? variables,
  }) {
    final vars = variables ?? <String, String>{};
    final effectiveBaseUrl = baseUrl.isEmpty ? source.bookSourceUrl : baseUrl;

    // 走 UrlRuleAnalyzer 解析，支持 Legado 的 `url,{"method":"POST","body":"..."}` 语法。
    //
    // 原版 Kotlin 的 `java.ajax` 用 AnalyzeUrl 解析整串，因此书源里
    // `java.ajax(host + "/morechapter,{\"method\":\"POST\",\"body\":\"id=\" + id + "\"}")`
    // 这种「URL + JSON 后缀」能真正发出 POST；当成普通 URL GET 会拿到错误页面。
    Future<Object?> fetchUrl(String rawUrl) async {
      try {
        final analyzer = UrlRuleAnalyzer(
          _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
        );
        final analyzed = await analyzer.analyze(rawUrl, baseUrl: effectiveBaseUrl);
        final response = await _request(
          analyzed,
          extraHeaders: _sourceHeaders(source),
        );
        return response.text();
      } catch (e) {
        return null;
      }
    }

    return createJavaObject(
      ajax: (url) => fetchUrl(url),
      get: (url) => fetchUrl(url),
      post: (url, body, hdrs) async {
        try {
          final analyzer = UrlRuleAnalyzer(
            _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
          );
          // 显式 body 优先于 URL 后缀里的 body。
          final rule =
              body == null ? url : '$url,{"body":${jsonEncode(body.toString())}}';
          final analyzed = await analyzer.analyze(rule, baseUrl: effectiveBaseUrl);
          final response = await _request(
            analyzed,
            extraHeaders: _sourceHeaders(source),
          );
          return response.text();
        } catch (e) {
          return null;
        }
      },
      getString: (rule) async {
        final analyze = AnalyzeRule(
          _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
        );
        return analyze.getString(rule);
      },
      getElements: (rule) async {
        final analyze = AnalyzeRule(
          _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
        );
        return analyze.getElements(rule);
      },
      getList: (rule) async {
        final analyze = AnalyzeRule(
          _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
        );
        return analyze.getStringList(rule);
      },
      variables: vars,
      props: source.toJson(),
    );
  }

  /// 书源自带的请求头（`header` 字段是 JSON 字符串）。
  Map<String, String> _sourceHeaders(BookSource source) {
    final raw = source.header;
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      // header 不是合法 JSON 就当没有，不影响其余规则。
    }
    return const {};
  }

  /// 发请求。
  ///
  /// [extraHeaders] 是书源自带的请求头（`header` 字段）。它必须在 URL 规则里
  /// 声明的头之后、但优先级更低：书源作者在 `header` 里写的 UA/Referer 是全局
  /// 默认值，具体某条规则写的 `headers` 才应该覆盖它。
  Future<HttpResponse> _request(
    AnalyzedUrl analyzed, {
    Map<String, String> extraHeaders = const {},
  }) {
    final uri = Uri.tryParse(analyzed.url);
    if (uri == null) {
      throw LegadoException(ErrorCode.invalid, '非法请求地址: ${analyzed.url}');
    }
    final headers = <String, String>{...extraHeaders, ...analyzed.headers};
    final client = headers.isEmpty ? _net : _net.withHeaders(headers);
    final Future<HttpResponse> response;
    if (analyzed.method.toUpperCase() == 'POST') {
      response = client.post(
        uri,
        body: _postBody(analyzed),
        headers: _postHeaders(analyzed),
        charset: analyzed.charset,
      );
    } else {
      response = client.get(uri, charset: analyzed.charset);
    }
    return response;
  }

  /// POST 的请求体。
  ///
  /// 这里必须自己决定「用字符串还是字节」，因为网络层只有在拿到 String 时
  /// 才会推断 Content-Type。直接把原始字节丢过去，请求里就没有
  /// Content-Type，PHP 站点会把请求体当二进制丢掉——
  /// 症状是接口正常返回 200，但内容是「没有更多数据了」这类空结果。
  Object? _postBody(AnalyzedUrl analyzed) {
    final body = analyzed.body;
    if (body == null || body.isEmpty) return null;
    final charset = analyzed.charset;
    if (_declaredContentType(analyzed) != null) {
      // 规则自己声明了 Content-Type：body 按目标编码原样发送。
      return encode(body, charset: charset);
    }
    if (isJsonLikeBody(body)) {
      // JSON：交回网络层，它会带上 application/json。
      return body;
    }
    // 表单：百分号转义 + 按目标编码取字节。
    return encodeFormBody(body, charset: charset);
  }

  /// POST 额外请求头。
  ///
  /// 规则里写了 Content-Type 就用它；否则表单要显式补上，
  /// 否则服务端解析不出表单字段。
  Map<String, String> _postHeaders(AnalyzedUrl analyzed) {
    if (_declaredContentType(analyzed) != null) return const {};
    final body = analyzed.body;
    if (body == null || body.isEmpty) return const {};
    if (isJsonLikeBody(body)) return const {};
    final charset = analyzed.charset;
    return {
      'Content-Type':
          'application/x-www-form-urlencoded; charset=${charset ?? 'UTF-8'}',
    };
  }

  /// 规则里显式声明的 Content-Type（大小写不敏感）。
  String? _declaredContentType(AnalyzedUrl analyzed) {
    for (final entry in analyzed.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type') return entry.value;
    }
    return null;
  }

  Future<String> _first(
    AnalyzeRule analyze,
    String? rule,
    Object? element, {
    bool isUrl = false,
  }) async {
    final values = await analyze.getStringList(rule, element, isUrl);
    return values.isEmpty ? '' : values.first.trim();
  }

  Map<String, String> _decodeVariables(String raw) {
    if (raw.trim().isEmpty) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return {
          for (final entry in decoded.entries) '${entry.key}': '${entry.value}',
        };
      }
    } on FormatException {
      // 变量串是书源自由格式，解析不了就当没有。
    }
    return <String, String>{};
  }

  /// 详情规则没解出封面时用列表页已拿到的封面兜底。
  ///
  /// 很多书源（如超星）把封面写在搜索/发现规则里，`ruleBookInfo.coverUrl`
  /// 留空；详情页重解析时若不留住这张图，用户从列表点进去封面就消失了。
  String _withFallbackCover(String parsed, String fallback) {
    final value = parsed.trim();
    if (value.isNotEmpty && value.startsWith('http')) return value;
    final candidate = fallback.trim();
    return candidate.startsWith('http') ? candidate : '';
  }

  bool _flag(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return switch (value.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        _ => false,
      };
    }
    return false;
  }

  String _looseJson(String input) {
    final buffer = StringBuffer();
    var inString = false;
    var escaped = false;
    var i = 0;
    while (i < input.length) {
      final ch = input[i];
      if (inString) {
        buffer.write(ch);
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        i++;
        continue;
      }
      if (ch == '"') {
        inString = true;
        buffer.write(ch);
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < input.length && input[i + 1] == '/') {
        while (i < input.length && input[i] != '\n') {
          i++;
        }
        continue;
      }
      if (ch == ',') {
        var j = i + 1;
        while (j < input.length && (input[j] == ' ' || input[j] == '\n' ||
            input[j] == '\r' || input[j] == '\t')) {
          j++;
        }
        if (j < input.length && (input[j] == ']' || input[j] == '}')) {
          i++;
          continue;
        }
      }
      buffer.write(ch);
      i++;
    }
    return buffer.toString();
  }
}

class _BookMeta {
 const _BookMeta({
    required this.name,
    required this.author,
    required this.intro,
    required this.kind,
    required this.cover,
    required this.lastChapter,
  });

  final String name;
  final String author;
  final String intro;
  final String kind;
  final String cover;
  final String lastChapter;
}
