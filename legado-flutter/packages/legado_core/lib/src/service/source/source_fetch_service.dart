import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import '../../domain/domain.dart';
import '../../js/java_host.dart';
import '../../js/js_engine.dart';
import '../../js/js_engine_factory.dart';
import '../../js/str_response.dart';
import '../../js/values.dart';
import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../../rules/rules.dart';
import '../../store/dao/book_source_dao.dart';
import '../../store/database.dart';
import '../../store/store.dart';
import '../../util/url.dart';
import '../replacerule/replacement_processor.dart';
import 'chapter_progress_match.dart';
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

/// 一页（或一整章）正文的抓取结果。
///
/// [title] 来自 `ruleContent.title`，多数书源不配该规则，此时为 null，
/// 上层沿用目录里的标题。
class FetchedContent {
  const FetchedContent(this.html, this.images, {this.title});

  final String html;
  final List<String> images;
  final String? title;
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
    String homeDir = '',
  })  : _daos = daos,
        _shelf = shelf,
        _homeDir = homeDir,
        _net = NetClient(),
        _js = createJsEngine(onLog: _logJsMessage);

  final StoreDaos _daos;
  final ShelfService _shelf;
  final NetClient _net;
  final JsEngine _js;

  /// 书源脚本里 `cache.put/get` 的存储。
  ///
  /// 原版 `CacheManager` 会落盘并按 saveTime 过期；书源实际只用它跨规则传
  /// 临时值（token、页面里的动态 key），进程内共享一份 Map 就够用。
  final Map<String, Object?> _jsCache = <String, Object?>{};

  /// 按书源 `concurrentRate` 限速（每个书源一个闸门，见 [SourceRateGate]）。
  final SourceRateGateRegistry _rateGates = SourceRateGateRegistry();

  /// 数据目录：`cookies.json` 落在这里，登录态才能跨进程保留。
  final String _homeDir;

  /// 登录域复用的网络层。
  ///
  /// 必须是同一个实例：cookie 存在 [NetClient] 自带的 [CookieStore] 里，
  /// 登录域另起一个客户端会让「登录成功」与「抓正文带不上 cookie」同时成立。
  NetClient get net => _net;

  /// 登录域复用的脚本引擎（jsLib、java 宿主、限流都跟抓取链路一致）。
  JsEngine get js => _js;

  /// 按整数 ID 取书源。找不到抛 NOT_FOUND。
  BookSource requireSource(int id) => _requireSource(id);

  /// 书源自带的请求头（`header` 字段的 JSON）。
  Map<String, String> headersOf(BookSource source) => _sourceHeaders(source);

  /// 构造带网络能力的 `java` 宿主（登录脚本要 `java.ajax/post`）。
  Object javaHostOf(BookSource source, {Map<String, String>? variables}) =>
      _javaHost(source, variables: variables);

  /// 按已解析的 URL 规则发请求（登录域的 `url,{"method":...}` 形态复用）。
  Future<HttpResponse> requestAnalyzed(
    BookSource source,
    AnalyzedUrl analyzed,
  ) =>
      _request(
        analyzed,
        extraHeaders: _sourceHeaders(source),
        source: source,
      );

  /// 登录 / 探测用的通用请求：GET 或表单 POST，自动叠加书源请求头。
  Future<HttpResponse> requestUrl(
    BookSource source,
    String url, {
    String method = 'GET',
    Map<String, String>? form,
    Map<String, String>? headers,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw LegadoException(ErrorCode.invalid, '非法请求地址: $url');
    }
    final merged = <String, String>{..._sourceHeaders(source), ...?headers};
    final client = merged.isEmpty ? _net : _net.withHeaders(merged);
    Future<HttpResponse> send() {
      if (method.toUpperCase() == 'POST') {
        return client.postForm(uri, form ?? const <String, String>{});
      }
      return client.get(uri);
    }

    // 这条路径绕开了 `_request`（登录/校验用它发任意 URL），
    // 限速得单独套一层，否则配了 concurrentRate 的源在登录时仍会打满。
    final gate = _rateGates.gateOf(source.bookSourceUrl, source.concurrentRate);
    return gate == null ? send() : gate.run(send);
  }

  String get _cookiePath =>
      _homeDir.isEmpty ? '' : p.join(_homeDir, 'cookies.json');

  Future<void>? _cookiesLoaded;

  /// 载入持久化的 cookie（幂等；失败不阻塞抓取）。
  Future<void> restoreCookies() {
    if (_cookiePath.isEmpty) return Future<void>.value();
    return _cookiesLoaded ??= _net.loadCookies(_cookiePath);
  }

  /// 把当前 cookie 落盘。登录成功后必须调，否则进程重启登录态就没了。
  Future<void> persistCookies() async {
    if (_cookiePath.isEmpty) return;
    await _net.saveCookies(_cookiePath);
  }

  void close() {
    _net.close();
    _js.dispose();
  }

  // ---- 发现 -----------------------------------------------------------

  List<ExploreSourceBrief> listExploreSources() {
    final out = <ExploreSourceBrief>[];
    for (final source in _daos.bookSource.all) {
      // 原版 `flowExplore()` 的条件只有 `enabledExplore = 1 and hasExploreUrl = 1`
      // —— 不看 `enabled`。用户把书源「停用」只是不再参与搜索，发现页仍可浏览；
      // 这里曾多判一个 `enabled`，停用过的源在发现页会凭空消失。
      if (!source.enabledExplore) continue;
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

  /// 全部（或指定范围内）启用源搜索。
  ///
  /// [scope] 沿用原版 `SearchScope` 的字符串格式：
  /// * 空：全部启用书源；
  /// * `书源名::书源地址`：单个书源（只按地址取，名称仅用于展示）；
  /// * `分组1,分组2`：属于这些分组的启用书源（多分组并存去重）。
  /// 范围为空或解析不到任何源时回退全部启用源，与原版一致——
  /// 用户删了书源后不该搜出 0 条而以为书全没了。
  Future<List<SearchResultView>> searchAll(
    String keyword,
    int page, [
    String scope = '',
  ]) async {
    final enabled = _daos.bookSource.all.where((source) => source.enabled).toList();
    final sources = _filterSourcesByScope(enabled, scope)
      ..sort((a, b) => a.customOrder.compareTo(b.customOrder));
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

  List<BookSource> _filterSourcesByScope(
    List<BookSource> enabled,
    String scope,
  ) {
    final raw = scope.trim();
    if (raw.isEmpty) return enabled;

    final separator = raw.indexOf('::');
    if (separator >= 0) {
      final url = raw.substring(separator + 2).trim();
      final picked = enabled.where((s) => s.bookSourceUrl == url).toList();
      return picked.isEmpty ? enabled : picked;
    }

    final groups = {
      for (final part in raw.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    };
    final picked = enabled.where(
      (source) => source.groups.any(groups.contains),
    ).toList();
    return picked.isEmpty ? enabled : picked;
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
    var response = await _request(
      analyzed,
      extraHeaders: _sourceHeaders(source),
      source: source,
    );
    // 原版 WebBook.searchBookAwait / exploreBookAwait：拿到响应先过 loginCheckJs。
    response = await _applyLoginCheckJs(source, response);
    final body = response.text();
    // **同一个变量表**：searchUrl / exploreUrl 里的 `@put:{k:v}`（比如先请求
    // 一次拿 token）写在 analysis 用的 context 里，字段规则必须能读到。
    // 原来这里另建了一个空变量表的 context，`@put` 结果全丢，表现为
    // 「搜索能出结果，但点进去详情/正文 401」。
    final analyze = AnalyzeRule(
      _contextOf(
        source,
        baseUrl: response.finalUri.toString(),
        variables: context.variables,
      ),
    );

    var ruleMap = _decodeRuleMap(
      useExploreRule ? source.ruleExplore : source.ruleSearch,
    );
    // 原版 `BookList.getBookList`：发现规则没写 bookList 时整段回退搜索规则。
    // 很多源只配了 ruleSearch，发现页靠 searchUrl 驱动；不回退就是 0 条。
    if (useExploreRule && '${ruleMap['bookList'] ?? ''}'.trim().isEmpty) {
      ruleMap = _decodeRuleMap(source.ruleSearch);
    }
    // `bookList` 的 `-` 前缀 = 结果倒序，`+` 前缀 = 仅作显式声明（原版同）。
    var listRule = '${ruleMap['bookList'] ?? ''}'.trim();
    var reverse = false;
    if (listRule.startsWith('-')) {
      reverse = true;
      listRule = listRule.substring(1);
    } else if (listRule.startsWith('+')) {
      listRule = listRule.substring(1);
    }
    if (listRule != '${ruleMap['bookList'] ?? ''}') {
      ruleMap = {...ruleMap, 'bookList': listRule};
    }

    final rule = SearchRule.fromJson(ruleMap);
    final items = await analyze.getElements(rule.bookList, body);
    final out = <SearchResultView>[];
    for (var i = 0; i < items.length; i++) {
      final element = items[i];
      final name = _formatBookName(await _first(analyze, rule.name, element));
      // 原版：书名为空直接跳过这条（后面所有字段都以它为前提）。
      if (name.isEmpty) continue;
      final bookUrl = await _first(analyze, rule.bookUrl, element, isUrl: true);
      if (bookUrl.isEmpty) continue;
      final author = _formatBookAuthor(await _first(analyze, rule.author, element));
      final cover = await _first(analyze, rule.coverUrl, element, isUrl: true);
      final intro = await _first(analyze, rule.intro, element);
      final lastChapter = await _first(analyze, rule.lastChapter, element);
      // 分类是多值：原版 `getStringList(...).joinToString(",")`，
      // 只取第一条会把「玄幻,热血」截成「玄幻」。
      final kinds = await analyze.getStringList(rule.kind, element);
      // 变量必须在**字段规则跑完之后**取快照：字段里的 `@put` 也要带出去。
      final variables = <String, String>{...analyze.context.variables};
      out.add(SearchResultView(
        name: name,
        author: author,
        cover: cover,
        intro: intro,
        bookUrl: bookUrl,
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        lastChapter: lastChapter,
        kind: kinds.join(','),
        variable: jsonEncode(variables),
      ));
    }
    if (reverse) return out.reversed.toList(growable: false);
    return out;
  }

  /// 书源规则 JSON → Map；解析不了按空规则处理（宽松解析，不抛）。
  Map<String, Object?> _decodeRuleMap(String? raw) {
    final text = (raw ?? '').trim();
    if (text.isEmpty) return <String, Object?>{};
    try {
      final decoded = jsonDecode(_looseJson(text));
      return decoded is Map ? decoded.cast<String, Object?>() : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  /// 书名规范化（原版 `BookHelp.formatBookName`）：去掉「 作者：xxx」「 xxx 著」。
  static String _formatBookName(String raw) =>
      raw.replaceAll(RegExp(r'\s+作\s*者.*|\s+\S+\s+著'), '').trim();

  /// 作者规范化（原版 `BookHelp.formatBookAuthor`）：去掉前缀「作者：」与「 著」。
  static String _formatBookAuthor(String raw) =>
      raw.replaceAll(RegExp(r'^\s*作\s*者[:：\s]+|\s+著'), '').trim();

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
    // 新书入库时目录就是「最新」的，直接把 latestChapterTime 记为当前时间，
    // 否则书架「按更新时间」排序时新加的书会排到最底下（原版也在这里同步）。
    book.latestChapterTime = book.lastCheckTime;
    // 原版 `BookChapterList` 的 `lastCheckCount = list.size - totalChapterNum`
    // 对新书就是「全部章节都算新增」，书架角标据此点亮；读过后由 ReadBook 清零。
    book.lastCheckCount = chapters.length;

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
    var response = await client.get(Uri.parse(bookUrl));
    // 原版 WebBook.getBookInfoAwait：详情响应也要过 loginCheckJs。
    response = await _applyLoginCheckJs(source, response);
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
    // 详情页初始化规则：`init` 的求值结果替换整页内容。
    // 部分源用它解混淆（页面里塞了一层 `<script>` 生成的 HTML），
    // 不执行的话后面所有字段规则都命中不到。
    var content = body;
    final initRule = (rule.init ?? '').trim();
    if (initRule.isNotEmpty) {
      final initialized = await analyze.getString(initRule, body);
      if (initialized.trim().isNotEmpty) content = initialized;
    }
    Future<String> pick(String? r, [String fallback = '']) async {
      final value = await analyze.getString(r, content);
      return value.isEmpty ? fallback : value;
    }

    final parsedCover = await analyze.getString(rule.coverUrl, content, true);
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
    final tocUrl = await analyze.getString(rule.tocUrl, content, true);
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

    var ruleMap = <String, Object?>{};
    try {
      final decoded = jsonDecode(_looseJson(source.ruleToc ?? '{}'));
      if (decoded is Map) ruleMap = decoded.cast<String, Object?>();
    } on FormatException {
      // 目录规则缺失时返回空目录，交给调用方报错。
    }
    final rule = TocRule.fromJson(ruleMap);

    // 目录更新前脚本：书源用它刷新变量 / 处理登录态（原版 WebBook.runPreUpdateJs）。
    // 失败不阻断目录抓取，只是少了脚本带来的预处理。
    final preUpdateJs = (rule.preUpdateJs ?? '').trim();
    if (preUpdateJs.isNotEmpty) {
      try {
        await _contextOf(
          source,
          variables: context.variables,
          extra: context.extraBindings,
        ).evalJs(preUpdateJs, null);
      } catch (e) {
        _log.warning('preUpdateJs 执行失败(${source.bookSourceName}): $e');
      }
    }

    // 规则前缀：`-` 表示该规则返回的是倒序（最新章节在前），`+` 强制正序。
    // 对齐 Kotlin `BookChapterList.analyzeChapterList`。
    var listRule = (rule.chapterList ?? '').trim();
    var reverse = false;
    if (listRule.startsWith('-')) {
      reverse = true;
      listRule = listRule.substring(1).trim();
    } else if (listRule.startsWith('+')) {
      listRule = listRule.substring(1).trim();
    }

    // 目录分页：`nextTocUrl` 一次可能给出多个地址（老站常把第 2~7 页一起写出来）。
    // 用队列逐页抓，visited 去重 —— 站点把当前页也写进下一页列表时不会死循环。
    final raw = <BookChapter>[];
    final visited = <String>{};
    final pending = <String>[tocUrl];
    while (pending.isNotEmpty && visited.length < 64) {
      final pageUrl = pending.removeAt(0);
      if (pageUrl.isEmpty || !visited.add(pageUrl)) continue;
      var response = await client.get(Uri.parse(pageUrl));
      // 原版 WebBook.getChapterListAwait：目录响应也要过 loginCheckJs。
      response = await _applyLoginCheckJs(source, response);
      if (!response.isSuccess) {
        // 第一页就失败说明整个目录拿不到；后续页失败只能接受残缺目录。
        if (raw.isEmpty) {
          throw LegadoException(
            ErrorCode.netTimeout,
            '获取目录失败: HTTP ${response.statusCode}',
          );
        }
        break;
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
      final items = await analyze.getElements(listRule, body);
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final title = await _first(analyze, rule.chapterName, item);
        final url = await _first(analyze, rule.chapterUrl, item, isUrl: true);
        if (url.isEmpty) continue;
        raw.add(BookChapter(
          url: url,
          bookUrl: bookUrl,
          title: title.isEmpty ? '第 ${raw.length + 1} 章' : title,
          isVolume: _flag(await _first(analyze, rule.isVolume, item)),
          isVip: _flag(await _first(analyze, rule.isVip, item)),
          isPay: _flag(await _first(analyze, rule.isPay, item)),
        ));
      }
      if ((rule.nextTocUrl ?? '').isEmpty) break;
      for (final next
          in await analyze.getStringList(rule.nextTocUrl, body, true)) {
        if (next.isNotEmpty && !visited.contains(next)) pending.add(next);
      }
    }

    if (raw.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书源目录没有解析出章节');
    }

    // 倒序规则先翻成阅读顺序，之后去重与编号都按阅读顺序算。
    final ordered = reverse ? raw.reversed.toList(growable: false) : raw;

    // 去重：同一章节地址只保留**最后一次出现**。
    //
    // 旧站目录页常把「最新章节」区块和正文目录放进同一个容器，同一 URL 会出现两次；
    // 而 chapters 表主键是 (url, bookUrl) 且写入用 INSERT OR REPLACE，重复行会互相
    // 覆盖 —— 若保留先出现的那条，后一条携带的大 index 覆盖之后，前面的 index 就
    // 成了空洞，`Reader.GetChapters` 按 index 排序返回的序列不再是 0..n-1，
    // 阅读器按列表下标取章节时就会整体错位（点第 N 章看到第 N+k 章）。
    final lastAt = <String, int>{};
    for (var i = 0; i < ordered.length; i++) {
      lastAt[ordered[i].url] = i;
    }
    final positions = lastAt.values.toList()..sort();
    final out = <BookChapter>[];
    for (final position in positions) {
      final chapter = ordered[position];
      // 去重后重新编号，保证落库的 index 一定是 0..n-1 连续。
      chapter.index = out.length;
      out.add(chapter);
    }
    if (out.length != ordered.length) {
      _log.info(
        '目录去重 ${source.bookSourceName}: 原始 ${ordered.length} 条，'
        '丢弃重复 ${ordered.length - out.length} 条',
      );
    }

    // 标题格式化：原版把每章作为 `chapter`、序号作为 `index`（从 1 开始）
    // 注入脚本，脚本的返回值就是新标题。很多源用它补齐「第X章」前缀。
    final formatJs = (rule.formatJs ?? '').trim();
    if (formatJs.isNotEmpty) {
      for (var i = 0; i < out.length; i++) {
        final chapter = out[i];
        try {
          final value = await _contextOf(
            source,
            variables: context.variables,
            extra: {
              ...context.extraBindings,
              'index': i + 1,
              'chapter': chapter.toRow(),
              'title': chapter.title,
            },
          ).evalJs(formatJs, null);
          final title = value?.toString().trim() ?? '';
          if (title.isNotEmpty) chapter.title = title;
        } catch (e) {
          _log.warning('formatJs 执行失败(${source.bookSourceName}) 第 ${i + 1} 章: $e');
        }
      }
    }
    return out;
  }

  /// 换源：把一本书迁到另一个书源（或同源换一个书籍地址）。
  ///
  /// 语义对齐 Kotlin `BookshelfViewModel.changeBookSource`：
  /// - 书本身保留（分组、排序、自定义封面/简介都不动），只换 `bookUrl` 与来源；
  /// - 目录整体重建；
  /// - 阅读进度按**章节序号**保留（不同源章节数不同，夹在边界内）；
  /// - `chapters` / `reading_progress` / `chapter_cache` 都以 `bookUrl` 或
  ///   `bookId` 关联，所以实现是「删旧书 → 插新书 → 插新章节」，不是改主键。
  Future<Map<String, Object?>> changeSource(
    int bookId,
    int sourceId,
    String newBookUrl,
  ) async {
    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }
    if (book.isLocal) {
      throw const LegadoException(ErrorCode.invalid, '本地书不支持换源');
    }
    final source = _requireSource(sourceId);
    final targetUrl = newBookUrl.trim().isEmpty
        ? book.bookUrl
        : newBookUrl.trim();
    if (targetUrl == book.bookUrl && source.bookSourceUrl == book.origin) {
      return <String, Object?>{'bookId': bookId, 'book': _shelf.getBook(bookId)};
    }
    final occupied = _daos.book.getByUrl(targetUrl);
    if (occupied != null && occupied.bookUrl != book.bookUrl) {
      throw LegadoException(
        ErrorCode.invalid,
        '目标书籍已在书架中: ${occupied.name}',
      );
    }

    final context = _contextOf(source);
    final (meta, tocUrl) = await _fetchInfo(
      context,
      source,
      targetUrl,
      book.name,
      book.author,
      book.displayCover,
    );
    final chapters = await _fetchToc(context, source, tocUrl, targetUrl);

    final oldUrl = book.bookUrl;
    final oldProgress = _daos.readingProgress.get(oldUrl);
    final oldIndex = oldProgress?.chapterIndex ?? book.durChapterIndex;
    final oldTitle = oldProgress?.chapterTitle ?? book.durChapterTitle;
    // 进度迁移按**章节名/章节号**匹配，不是按序号 clamp（原版
    // `Book.migrateTo → BookHelp.getDurChapter`）。新源少几章前言、多几章番外
    // 时序号会整体偏移，直接 clamp 会把用户扔到完全不相干的一章。
    final index = chapters.isEmpty
        ? 0
        : migrateChapterIndex(
            oldIndex: oldIndex,
            oldTitle: oldTitle,
            newChapterTitles: [for (final c in chapters) c.title],
            oldChapterListSize: book.totalChapterNum,
          ).clamp(0, chapters.length - 1);
    final now = DateTime.now().millisecondsSinceEpoch;

    final moved = book.copyWith(
      bookUrl: targetUrl,
      origin: source.bookSourceUrl,
      originName: source.bookSourceName,
      tocUrl: tocUrl,
      name: meta.name.trim().isEmpty ? book.name : meta.name.trim(),
      author: meta.author.trim().isEmpty ? book.author : meta.author.trim(),
      kind: meta.kind.trim().isEmpty ? book.kind : meta.kind,
      coverUrl: meta.cover.trim().isEmpty ? book.coverUrl : meta.cover,
      intro: meta.intro.trim().isEmpty ? book.intro : meta.intro,
      totalChapterNum: chapters.length,
      latestChapterTitle:
          chapters.isEmpty ? book.latestChapterTitle : chapters.last.title,
      latestChapterTime: now,
      lastCheckTime: now,
      durChapterIndex: index,
      durChapterTitle: chapters.isEmpty
          ? book.durChapterTitle
          : chapters[index].title,
      durChapterPos: oldProgress?.chapterPos ?? book.durChapterPos,
    );

    runInTransaction(_daos.db, () {
      // 顺序要紧：先删旧书（级联删 chapters），再插新书，最后插新章节。
      _daos.book.deleteByUrl(oldUrl);
      _daos.readingProgress.delete(oldUrl);
      _daos.cache.deleteByPrefix('chapter_$bookId');
      _daos.book.insert(moved);
      for (final chapter in chapters) {
        _daos.chapter.insert(chapter);
      }
      if (oldProgress != null) {
        _daos.readingProgress.put(
          ReadingProgress(
            bookUrl: targetUrl,
            chapterIndex: index,
            chapterTitle: chapters.isEmpty
                ? oldProgress.chapterTitle
                : chapters[index].title,
            chapterPos: oldProgress.chapterPos,
            scrollPercent: oldProgress.scrollPercent,
            updatedAt: now,
          ),
        );
      }
    });

    final newId = _rowId(targetUrl);
    return <String, Object?>{
      'bookId': newId,
      'oldBookId': bookId,
      'book': _shelf.getBook(newId),
    };
  }

  /// 批量换源：对齐原版 `BookshelfManageViewModel.changeSource`。
  ///
  /// 逐本在指定书源里按「书名 + 作者」精确搜索，命中后走 [changeSource]
  /// （详情 + 目录 + 进度迁移都在那里）。本地书、已经是该源的书直接跳过；
  /// 单本失败不阻断其余，错误逐条回给 UI 汇总。
  Future<Map<String, Object?>> batchChangeSource(
    List<int> bookIds,
    int sourceId,
  ) async {
    final source = _requireSource(sourceId);
    var succeeded = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    for (final id in bookIds) {
      final book = _daos.book.getById(id);
      if (book == null) {
        skipped++;
        continue;
      }
      if (book.isLocal || book.origin == source.bookSourceUrl) {
        skipped++;
        continue;
      }
      try {
        final hit = await _preciseSearch(source, book.name, book.author);
        if (hit == null) {
          skipped++;
          continue;
        }
        // 不能因为 bookUrl 相同就跳过：两个源常指向同一个详情页地址，
        // 换的其实是 origin（规则来源）。changeSource 内部会处理「完全没变」。
        await changeSource(id, sourceId, hit.bookUrl);
        succeeded++;
      } on Object catch (e) {
        failed++;
        errors.add('${book.name}: $e');
      }
    }
    return <String, Object?>{
      'total': bookIds.length,
      'succeeded': succeeded,
      'skipped': skipped,
      'failed': failed,
      'errors': errors,
    };
  }

  /// 书架 JSON 导入：对齐原版 `BookshelfViewModel.importBookshelfByJson`。
  ///
  /// 输入可以是 JSON 数组文本，也可以是返回该数组的 http(s) 地址。每项按
  /// `name` / `author` 在全部启用书源里精确搜索，找到第一条即入库；
  /// 同名同作者已存在则跳过。返回逐项统计，UI 用来显示汇总。
  Future<Map<String, Object?>> importBookshelf(String input, int groupId) async {
    var text = input.trim();
    if (text.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '请填入书架 JSON 或地址');
    }
    final uri = Uri.tryParse(text);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty) {
      final response = await _net.get(uri);
      if (!response.isSuccess) {
        throw LegadoException(
          ErrorCode.netTimeout,
          '下载书架 JSON 失败: HTTP ${response.statusCode}',
        );
      }
      text = response.text();
    }

    // FormatException 不是 LegadoError，直接抛出去会被 UI 的异常分支漏掉，
    // 用户只看到「点了没反应」。这里统一转成可读错误。
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on Object {
      throw const LegadoException(ErrorCode.invalid, '书架 JSON 格式不对，请检查内容');
    }
    if (decoded is! List) {
      throw const LegadoException(ErrorCode.invalid, '书架 JSON 必须是数组');
    }
    final sources = _daos.bookSource.all.where((s) => s.enabled).toList();
    var total = 0;
    var added = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    for (final raw in decoded) {
      if (raw is! Map) {
        skipped++;
        continue;
      }
      final name = '${raw['name'] ?? ''}'.trim();
      final author = '${raw['author'] ?? ''}'.trim();
      if (name.isEmpty) {
        skipped++;
        continue;
      }
      total++;
      final duplicates = _daos.book.findByName([name]);
      if (duplicates.any((b) => b.author.trim() == author)) {
        skipped++;
        continue;
      }
      SearchResultView? hit;
      for (final source in sources) {
        try {
          hit = await _preciseSearch(source, name, author);
        } on Object {
          // 单源失败（没配搜索地址、网络超时）不影响其它书源。
        }
        if (hit != null) break;
      }
      if (hit == null) {
        skipped++;
        errors.add('$name: 没有书源搜到');
        continue;
      }
      // 详情里可能改名（搜索结果叫「搜索书名」、详情页叫「详情书名」），
      // 只按 JSON 里的书名查重会漏。命中 URL 已经在库里同样要跳过。
      if (_daos.book.getByUrl(hit.bookUrl) != null) {
        skipped++;
        continue;
      }
      try {
        await upsertBook(
          _sourceRowId(hit.origin),
          hit.bookUrl,
          hit.name,
          hit.author,
          hit.variable,
          groupId,
          true,
          hit.cover,
        );
        added++;
      } on Object catch (e) {
        failed++;
        errors.add('$name: $e');
      }
    }
    return <String, Object?>{
      'total': total,
      'added': added,
      'skipped': skipped,
      'failed': failed,
      'errors': errors,
    };
  }

  /// 原版 `WebBook.preciseSearchAwait`：书名必须完全一致，作者给了也要一致。
  /// 搜不到就返回 null，绝不拿模糊结果冒充（否则批量换源会换到别的小说）。
  Future<SearchResultView?> _preciseSearch(
    BookSource source,
    String name,
    String author,
  ) async {
    // 对齐原版 WebBook.preciseSearchAwait：只用书名做搜索关键词，作者仅用于
    // 过滤结果。早期实现拼成 `书名 作者`，多数书源会把整串当书名 → 搜到 0 条
    // → 导入书架/批量换源静默跳过，用户看到的就是「导入后书架没书」。
    final results = await search(_sourceRowId(source.bookSourceUrl), name, 1);
    for (final result in results) {
      if (result.name.trim() != name) continue;
      if (author.isNotEmpty && result.author.trim() != author) continue;
      return result;
    }
    return null;
  }

  /// 更新目录：对齐 Kotlin `MainViewModel.updateToc`。
  ///
  /// - 本地书、书源已删除都直接报错，由 UI 汇总提示（原版是打 updateError 标记）；
  /// - 目录按 URL 整体替换：`chapters` 主键是 `(url, bookUrl)`，必须删后再插；
  /// - 阅读进度按**章节序号**保留，标题同步成新目录的标题（原版 `book.sync` 同口径）；
  /// - 正文缓存不主动删：缓存命中本来就要求章节 URL 一致，URL 变了自然失效。
  Future<Map<String, Object?>> refreshToc(int bookId) async {
    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }
    if (book.isLocal) {
      throw const LegadoException(ErrorCode.invalid, '本地书不支持更新目录');
    }
    final source = sourceByUrl(book.origin);
    if (source == null) {
      throw LegadoException(
        ErrorCode.notFound,
        '未找到书源 ${book.origin}，可能已被删除',
      );
    }
    final tocUrl =
        book.tocUrl.trim().isEmpty ? book.bookUrl : book.tocUrl.trim();
    final chapters = await _fetchToc(
      _contextOf(
        source,
        variables: _decodeVariables(book.variable ?? ''),
        extra: {'book': book.toRow()},
      ),
      source,
      tocUrl,
      book.bookUrl,
    );
    if (chapters.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '目录为空，未做改动');
    }

    final oldUrls = _daos.chapter.getUrls(book.bookUrl).toSet();
    final newUrls = chapters.map((c) => c.url).toSet();
    final added = newUrls.difference(oldUrls).length;
    final removed = oldUrls.difference(newUrls).length;
    final progress = _daos.readingProgress.get(book.bookUrl);
    final keepIndex =
        (progress?.chapterIndex ?? book.durChapterIndex).clamp(0, chapters.length - 1);
    final now = DateTime.now().millisecondsSinceEpoch;
    // 原版 `BookChapterList`：只有**真的多了章节**才刷新 `latestChapterTime`
    // /`lastCheckCount`。`lastCheckTime` 是「上次检查」，每次刷新都变，拿它
    // 排序会让没更新的书来回跳；书架「按更新时间」读的是 `latestChapterTime`。
    final oldTotal = book.totalChapterNum;
    final hasNewChapters = chapters.length > oldTotal;

    runInTransaction(_daos.db, () {
      _daos.chapter.deleteByBookUrl(book.bookUrl);
      // 不用 insertAll：它自己会再开一层事务。
      for (final chapter in chapters) {
        _daos.chapter.insert(chapter);
      }
      book
        ..totalChapterNum = chapters.length
        ..latestChapterTitle = chapters.last.title
        ..lastCheckTime = now
        ..durChapterIndex = keepIndex
        ..durChapterTitle = chapters[keepIndex].title;
      if (hasNewChapters) {
        book
          ..latestChapterTime = now
          ..lastCheckCount = chapters.length - oldTotal;
      }
      _daos.book.update(book);
      if (progress != null) {
        _daos.readingProgress.put(ReadingProgress(
          bookUrl: book.bookUrl,
          chapterIndex: keepIndex,
          chapterTitle: chapters[keepIndex].title,
          chapterPos: progress.chapterPos,
          scrollPercent: progress.scrollPercent,
          updatedAt: now,
        ));
      }
    });

    return <String, Object?>{
      'bookId': bookId,
      'total': chapters.length,
      'added': added,
      'removed': removed,
      'hasUpdate': added > 0 || removed > 0,
    };
  }

  /// 刷新书籍：对齐 Kotlin `BookInfoViewModel.refreshBook` + `loadBookInfo(canReName=false)`。
  ///
  /// 原版菜单「刷新」/详情页下拉走的是重抓详情 + 重抓目录，而不是只读本地库：
  /// - 详情：`WebBook.getBookInfo(canReName=false)` —— 只更新书源字段，不改书名/作者，
  ///   也不覆盖用户的自定义封面/简介/分类；
  /// - 目录：复用 [refreshToc] 整章替换并按章节序号保留进度。
  ///
  /// 本地书没有 WebDav 扫描能力（原版 refreshBook 的本地分支），直接报错由 UI 提示。
  Future<Map<String, Object?>> refreshBook(int bookId) async {
    final book = _daos.book.getById(bookId);
    if (book == null) {
      throw LegadoException(ErrorCode.notFound, '书籍不存在: $bookId');
    }
    if (book.isLocal) {
      throw const LegadoException(
        ErrorCode.invalid,
        '本地书不支持刷新详情，可在书架管理里重新导入',
      );
    }
    final source = sourceByUrl(book.origin);
    if (source == null) {
      throw LegadoException(
        ErrorCode.notFound,
        '未找到书源 ${book.origin}，可能已被删除',
      );
    }

    final variables = _decodeVariables(book.variable ?? '');
    // 详情规则里常写 {{book.bookUrl}}，与 upsertBook/refreshToc 一样注入 book 绑定。
    final context = _contextOf(
      source,
      variables: variables,
      extra: {'book': book.toRow()},
    );
    final (meta, tocUrl) = await _fetchInfo(
      context,
      source,
      book.bookUrl,
      book.name,
      book.author,
      book.displayCover,
    );

    // canReName=false：书名/作者保持库里的值；用户自定义字段不覆盖。
    book
      ..originName = source.bookSourceName
      ..tocUrl = tocUrl.trim().isEmpty ? book.bookUrl : tocUrl.trim()
      ..lastCheckTime = DateTime.now().millisecondsSinceEpoch;
    if (meta.cover.trim().isNotEmpty && (book.customCoverUrl ?? '').isEmpty) {
      book.coverUrl = meta.cover;
    }
    if (meta.intro.trim().isNotEmpty && (book.customIntro ?? '').isEmpty) {
      book.intro = meta.intro;
    }
    if (meta.kind.trim().isNotEmpty && (book.customTag ?? '').isEmpty) {
      book.kind = meta.kind;
    }
    book.latestChapterTitle = meta.lastChapter.trim().isEmpty
        ? book.latestChapterTitle
        : meta.lastChapter.trim();
    _daos.book.update(book);

    // 目录整章替换 + 进度保留走同一套逻辑（会重新 getById 读到上面更新的 tocUrl）。
    final tocResult = await refreshToc(bookId);
    return <String, Object?>{
      'bookId': bookId,
      'detailUpdated': true,
      ...tocResult,
    };
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
  /// 返回正文 HTML、图片直链列表与 `ruleContent.title` 解出的标题
  /// （没有该规则时为 null）。
  ///
  /// [bookUrl] 是书籍地址（用来定位书源与拼相对地址），[chapterUrl] 是章节地址。
  /// [chapterTitle] 是目录里的章节标题，作为脚本 `{{title}}` 的取值
  /// （对齐 Kotlin `BookContent` 的 `title` 绑定）。
  /// [nextChapterUrl] 是下一章地址，既作为脚本里的 `nextChapterUrl` 绑定，
  /// 也用于阻止翻页时误翻到下一章（对齐 Kotlin `BookContent.analyzeContent`）。
  ///
  /// 翻页语义照抄原版 `BookContent.analyzeContent`：
  /// - 解出 1 个下一页链接 → 串行抓，直到链接为空 / 已访问过 / 指向下一章；
  /// - 解出多个链接 → 并发抓（图片书分页常见），结果拼到正文末尾。
  Future<FetchedContent> fetchContent(
    BookSource source,
    String bookUrl,
    String chapterUrl, {
    String chapterTitle = '',
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
    Future<({
      String content,
      List<String> images,
      List<String> nextUrls,
      String finalUrl,
      String title
    })> loadPage(String fetchUrl, String baseForFetch) async {
      final analyzer = UrlRuleAnalyzer(
        _contextOf(source, baseUrl: baseForFetch),
      );
      final analyzed = await analyzer.analyze(fetchUrl, baseUrl: baseForFetch);
      var response =
          await _request(analyzed, extraHeaders: headers, source: source);
      // 原版 WebBook.getContentAwait：正文响应也要过 loginCheckJs。
      response = await _applyLoginCheckJs(source, response);
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
            'chapter': <String, Object?>{'url': chapterUrl, 'title': chapterTitle},
            'title': chapterTitle,
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
      // ruleContent.title：少数源的标题只在正文页（目录页只有「第1章」或空串）。
      // 只在配了标题规则时才求值，避免每页多跑一次解析。
      final titleRule = (rule.title ?? '').trim();
      final pageTitle =
          titleRule.isEmpty ? '' : (await analyze.getString(titleRule, body)).trim();
      return (
        content: content,
        images: images,
        nextUrls: nextUrls,
        finalUrl: redirectUrl,
        title: pageTitle,
      );
    }

    // ---- 首页 ----
    final first = await loadPage(chapterUrl, absolute);
    final pages = <String>[first.content];
    final allImages = <String>[...first.images];
    // 标题取首页结果；首页没解出时再往后页找（少数源标题在第一个分页里）。
    var contentTitle = first.title;
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
        if (contentTitle.isEmpty) contentTitle = page.title;
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
            if (contentTitle.isEmpty) contentTitle = page.title;
          }
        }
      }
    }

    var contentStr = pages.join('\n');
    if (contentStr.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '书源正文规则没有解析出内容');
    }
    // 替换净化：书源给的 HTML 里常年夹着广告、站点水印、无意义空行。
    // 放在退出前统一做一次，翻页拼接后的整章才不会被逐页规则漏掉。
    contentStr = ReplacementProcessor(_daos.replaceRule).content(
      contentStr,
      ReplacementTarget(
        bookName: _daos.book.getByUrl(bookUrl)?.name ?? '',
        origin: source.bookSourceUrl,
      ),
    );
    return FetchedContent(
      contentStr,
      allImages,
      title: contentTitle.isEmpty ? null : contentTitle,
    );
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
        // 书源变量（`Source.SetVariable` 存的 JSON，原版是 source_variables 表）：
        // 规则里 `{{token}}` 读、`@put:{k:v}` 写。不加载的话用户配置的变量永远读不到。
        // 调用方显式传入的变量（书籍 variable / 本次流程 `@put` 的结果）优先级更高。
        variables: {
          ..._decodeVariables(
            _daos.cache.get('sourceVariable_${source.bookSourceUrl}')?.value ?? '',
          ),
          ...?variables,
        },
        source: source.toJson(),
        // 书源 jsLib 是规则脚本的公共函数库，必须随每次求值一起注入，
        // 否则规则里调 jsLib 定义的函数会抛 ReferenceError。
        jsLib: source.jsLib ?? '',
        // `_javaHost` 内部会再构造上下文（给 java.getString 回调用），
        // 那层不能再带 java，否则无限递归。
        javaHost: withJava
            ? _javaHost(source, baseUrl: baseUrl, variables: variables)
            : null,
        // 原版 evalJS 的全局绑定里还有 `cookie` 与 `cache`：
        // 书源常写 `cookie.getCookie(baseUrl)`、`cache.put('k', v)`。
        // 少了它们会抛 ReferenceError，把整条规则打断。
        extraBindings: {
          'cookie': _cookieObject(),
          'cache': _cacheObject(),
          ...extra,
        },
      );

  /// 脚本里的 `cookie` 全局对象（对齐 Kotlin `CookieStore` 单例）。
  Object _cookieObject() => JsHostObject(
        label: 'cookie',
        methods: {
          // getCookie(url) 返回整条请求头，getKey(url, key) 取单个值。
          'getCookie': (args) {
            final uri = _uriOf(args);
            if (uri == null) return '';
            return _net.cookies.getCookieHeader(uri) ?? '';
          },
          'getKey': (args) {
            final uri = _uriOf(args);
            if (uri == null || args.length < 2) return '';
            return _net.cookies.cookieValue(uri, '${args[1]}') ?? '';
          },
          'setCookie': (args) {
            final uri = _uriOf(args);
            if (uri == null || args.length < 2) return null;
            _net.cookies.importCookieHeader(uri, '${args[1]}');
            return null;
          },
          // replaceCookie 语义是「整站覆盖」：先清空再写入，避免旧登录态残留。
          'replaceCookie': (args) {
            final uri = _uriOf(args);
            if (uri == null || args.length < 2) return null;
            _net.cookies.removeAll(uri);
            _net.cookies.importCookieHeader(uri, '${args[1]}');
            return null;
          },
          'removeCookie': (args) {
            final uri = _uriOf(args);
            if (uri == null) return null;
            _net.cookies.removeAll(uri);
            return null;
          },
        },
      );

  /// 脚本里的 `cache` 全局对象（对齐 Kotlin `CacheManager` 的常用方法）。
  Object _cacheObject() => JsHostObject(
        label: 'cache',
        methods: {
          'put': (args) {
            if (args.isEmpty) return null;
            _jsCache['${args[0]}'] = args.length > 1 ? args[1] : null;
            return null;
          },
          'get': (args) {
            if (args.isEmpty) return null;
            final v = _jsCache['${args[0]}'];
            return v?.toString();
          },
          'getInt': (args) => int.tryParse('${_jsCacheValue(args)}'),
          'getLong': (args) => int.tryParse('${_jsCacheValue(args)}'),
          'getDouble': (args) => double.tryParse('${_jsCacheValue(args)}'),
          'delete': (args) {
            if (args.isEmpty) return null;
            _jsCache.remove('${args[0]}');
            return null;
          },
        },
      );

  Object? _jsCacheValue(List<Object?> args) =>
      args.isEmpty ? null : _jsCache['${args[0]}'];

  /// JS 里传进来的 `{k: v}`（Map 或 JSON 文本）转请求头。
  Map<String, String> _headersOf(Object? raw) {
    if (raw is Map) {
      return {for (final e in raw.entries) '${e.key}': '${e.value}'};
    }
    if (raw is String && raw.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return {for (final e in decoded.entries) '${e.key}': '${e.value}'};
        }
      } catch (_) {
        // 不是合法 JSON 就当没有额外请求头。
      }
    }
    return const {};
  }

  Uri? _uriOf(List<Object?> args) {
    if (args.isEmpty) return null;
    final raw = '${args[0]}'.trim();
    if (raw.isEmpty) return null;
    return Uri.tryParse(raw);
  }

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
    Future<HttpResponse?> fetchRaw(
      String rawUrl, {
      Map<String, String> extraHeaders = const {},
    }) async {
      try {
        final analyzer = UrlRuleAnalyzer(
          _contextOf(source, baseUrl: effectiveBaseUrl, variables: vars, withJava: false),
        );
        final analyzed = await analyzer.analyze(rawUrl, baseUrl: effectiveBaseUrl);
        return await _request(
          analyzed,
          extraHeaders: {..._sourceHeaders(source), ...extraHeaders},
          source: source,
        );
      } catch (e) {
        return null;
      }
    }

    Future<Object?> fetchUrl(String rawUrl) async {
      final response = await fetchRaw(rawUrl);
      return response?.text();
    }

    /// `java.get/post/connect` 的返回值：原版是 OkHttp 的 `Response`，
    /// 书源一律写 `.body()` 取正文。这里用一个带同名方法的宿主对象对齐。
    Object? responseObject(HttpResponse? response) {
      if (response == null) return null;
      return JsHostObject(
        label: 'StrResponse',
        methods: {
          'body': (args) => response.text(),
          'url': (args) => response.finalUri.toString(),
          'statusCode': (args) => response.statusCode,
          'headers': (args) => <String, Object?>{
            for (final e in response.headers.entries) e.key: e.value.join(', '),
          },
          'toString': (args) => response.text(),
        },
      );
    }

    return createJavaObject(
      ajax: (url) => fetchUrl(url),
      ajaxAll: (urls) async =>
          await Future.wait([for (final url in urls) fetchUrl(url)]),
      // 书源常用 `java.getCookie(url)` 判断登录态、或取某个具名 cookie 拼请求头。
      getCookie: (url, key) {
        final uri = Uri.tryParse(url);
        if (uri == null) return '';
        try {
          if (key != null && key.isNotEmpty) {
            return _net.cookies.cookieValue(uri, key) ?? '';
          }
          return _net.cookies.getCookieHeader(uri) ?? '';
        } catch (_) {
          return '';
        }
      },
      // java.get(url, headers) 的返回值是响应对象（书源写 `.body()` 取正文），
      // 与 Kotlin 的 Connection.Response 一致。
      get: (url) async => responseObject(await fetchRaw(url)),
      connect: (url, headers, _) async {
        // Kotlin 的 `java.connect(urlStr, header)` 第二参就是请求头，
        // 不是 body（body 要写在 URL 串的 `,{"body":...}` 里）。
        return responseObject(
          await fetchRaw(url, extraHeaders: _headersOf(headers)),
        );
      },
      post: (url, body, hdrs) async {
        final headers = _headersOf(hdrs);
        // 显式 body 优先于 URL 后缀里的 body；method 必须是 POST，
        // 否则只会拼出一个带 body 的 GET（服务端拿不到表单）。
        final rule = body == null
            ? (url.contains('{"') ? url : '$url,{"method":"POST"}')
            : '$url,{"method":"POST","body":${jsonEncode(body.toString())}}';
        return responseObject(
          await fetchRaw(rule, extraHeaders: headers),
        );
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
      // ---- 人机验证（对齐 Kotlin JsExtensions）----
      startBrowser: (url, title) {
        // 不 await：`startBrowser` 的语义就是「开个窗给用户」，不等结果。
        // cookie 由验证页在每次加载完成后通过 `Source.ImportCookie` 实时回填。
        final handler = HostVerification.browser;
        final uri = Uri.tryParse(url);
        if (handler == null || uri == null || !uri.hasScheme) {
          throw const LegadoException(
            ErrorCode.unsupported,
            '当前宿主不支持内置浏览器验证',
          );
        }
        unawaited(
          handler(
            BrowserVerificationRequest(
              uri: uri,
              headers: browserSafeHeaders(_sourceHeaders(source)),
              title: title.trim().isEmpty ? source.bookSourceName : title.trim(),
              sourceKey: source.bookSourceUrl,
            ),
          ).catchError((Object e) {
            _log.warning('打开验证窗口失败：$e');
            return const BrowserVerificationResult(skipped: true);
          }),
        );
        return null;
      },
      startBrowserAwait: (url, title, refetch) async => strResponseObject(
        await _verifyWithBrowser(
          source,
          rawUrl: url,
          title: title,
          baseUrl: effectiveBaseUrl,
          variables: vars,
          refetchAfterSuccess: refetch,
        ),
        url: url,
      ),
      getVerificationCode: (imageUrl) async {
        final handler = HostVerification.captchaHandler;
        final uri = Uri.tryParse(imageUrl);
        if (handler == null || uri == null) {
          throw const LegadoException(
            ErrorCode.unsupported,
            '当前宿主不支持图片验证码输入',
          );
        }
        final code = await handler(uri);
        if (code == null || code.trim().isEmpty) {
          throw const LegadoException(ErrorCode.invalid, '验证码为空');
        }
        return code.trim();
      },
      variables: vars,
      props: source.toJson(),
    );
  }

  /// 书源自带的请求头（`header` 字段是 JSON 字符串）。
  ///
  /// 再叠加用户在登录面板粘贴的请求头：粘贴的那份是用户针对自己的账号
  /// （Cookie、UA、Referer）显式给的，优先级必须高于书源默认值。
  Map<String, String> _sourceHeaders(BookSource source) {
    final out = <String, String>{};
    final raw = source.header;
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) => out['$k'] = '$v');
        }
      } catch (_) {
        // header 不是合法 JSON 就当没有，不影响其余规则。
      }
    }
    final pasted = _daos.sourceLogin.get(source.bookSourceUrl)?.header ?? '';
    if (pasted.trim().isNotEmpty) {
      out.addAll(_parseHeaderText(pasted));
    }
    return out;
  }

  /// 解析粘贴的请求头文本（`Key: Value` 每行一条）。
  ///
  /// 只有 `<key>=<value>` 形态的行（浏览器复制出来的裸 Cookie 串）不算请求头，
  /// 那种由登录域单独走 cookie 导入，这里跳过即可。
  static Map<String, String> _parseHeaderText(String text) {
    final out = <String, String>{};
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final idx = trimmed.indexOf(':');
      if (idx <= 0) continue;
      final key = trimmed.substring(0, idx).trim().toLowerCase();
      final value = trimmed.substring(idx + 1).trim();
      if (key.isEmpty || value.isEmpty) continue;
      // HTTP/2 伪头（`:authority`、`:method`）没有冒号前的键名，走不到这里；
      // 这里再挡一次以 `:` 开头的行，避免把伪头当真实头发出去。
      if (key.startsWith(':')) continue;
      out[key] = value;
    }
    return out;
  }

  /// 给一次响应套上 `loginCheckJs`（原版 `WebBook` 里五处
  /// `evalJS(checkJs, result = res) as StrResponse`）。
  ///
  /// 语义：脚本通过 `result` 拿到当前响应（`result.body` / `result.url` /
  /// `result.code`），可以**直接改 `result.body`**，也可以 `return` 一个新字符串
  /// 或带 `body` 字段的对象。脚本里 `java.ajax` / `cookie` 与抓取链路共用同一份
  /// 客户端，所以「没登录就登录再抓一次」的常见写法也能跑通。
  ///
  /// 书源没配、脚本为空、脚本抛错时一律原样返回：检测登录态属于增强，
  /// 不能因为它失败就把整条搜索/详情/正文链路打断（原版同样用 try 包住）。
  Future<HttpResponse> _applyLoginCheckJs(
    BookSource source,
    HttpResponse response, {
    String? baseUrl,
  }) async {
    final raw = (source.loginCheckJs ?? '').trim();
    if (raw.isEmpty) return response;
    final script = _stripJsWrapper(raw);
    if (script.isEmpty) return response;

    final original = response.text();
    final result = JsHostObject(
      label: 'StrResponse',
      props: <String, Object?>{
        'body': original,
        'url': response.finalUri.toString(),
        'code': response.statusCode,
        'isSuccess': response.isSuccess,
      },
    );
    try {
      final returned = await _contextOf(
        source,
        baseUrl: baseUrl ?? response.finalUri.toString(),
      ).evalJs(script, result);
      final body = _bodyOfJsResult(returned) ?? '${result.props['body'] ?? ''}';
      if (body.isEmpty || body == original) return response;
      return HttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        bodyBytes: utf8.encode(body),
        finalUri: response.finalUri,
        // 脚本改过正文，响应头上的 charset 不再可信，按 UTF-8 解释。
        charsetHint: 'utf-8',
        elapsed: response.elapsed,
      );
    } on Object catch (e) {
      _log.warning('loginCheckJs 执行失败，按原响应继续: $e');
      return response;
    }
  }

  /// 只去掉整串包裹的 `<js>...</js>` / `@js:` 前缀。
  ///
  /// 原版把 `loginCheckJs` 当裸 JS 直接 eval（写前缀在 Rhino 里是语法错误），
  /// 但真实书源里确实有人这么写，这里容错一下。
  static String _stripJsWrapper(String raw) {
    final lower = raw.toLowerCase();
    if (lower.startsWith('@js:')) return raw.substring(4).trim();
    if (lower.startsWith('<js>')) {
      final close = RegExp(r'</js>\s*$', caseSensitive: false).firstMatch(raw);
      return raw.substring(4, close?.start ?? raw.length).trim();
    }
    return raw;
  }

  /// 脚本返回值里取正文：字符串直接当正文，对象取 `body`。
  static String? _bodyOfJsResult(Object? returned) {
    if (returned == null) return null;
    if (returned is String) return returned;
    if (returned is JsHostObject) {
      final body = returned.props['body'];
      return body == null ? null : '$body';
    }
    if (returned is Map) {
      final body = returned['body'];
      return body == null ? null : '$body';
    }
    return null;
  }

  /// 发请求。
  ///
  /// [extraHeaders] 是书源自带的请求头（`header` 字段）。它必须在 URL 规则里
  /// 声明的头之后、但优先级更低：书源作者在 `header` 里写的 UA/Referer 是全局
  /// 默认值，具体某条规则写的 `headers` 才应该覆盖它。
  Future<HttpResponse> _request(
    AnalyzedUrl analyzed, {
    Map<String, String> extraHeaders = const {},
    BookSource? source,
    bool promptOnChallenge = true,
  }) async {
    // 首次请求前把持久化的 cookie 载入（幂等）：登录态跨进程保留全靠它。
    await restoreCookies();
    final uri = Uri.tryParse(analyzed.url);
    if (uri == null) {
      throw LegadoException(ErrorCode.invalid, '非法请求地址: ${analyzed.url}');
    }
    final headers = <String, String>{...extraHeaders, ...analyzed.headers};
    final client = headers.isEmpty ? _net : _net.withHeaders(headers);
    // WebView 规则（`{"webView":true}` / `webJs`）：桌面与移动端都没有
    // 可编程的渲染环境，只能用普通 HTTP 顶上。打一条日志，免得书源作者
    // 以为自己的规则失效了。
    if (analyzed.useWebView || (analyzed.webJs ?? '').trim().isNotEmpty) {
      _log.info('规则要求 WebView 渲染，已退回普通 HTTP 请求: ${analyzed.ruleUrl}');
    }

    Future<HttpResponse> send() {
      // label 只服务反爬验证窗口的标题；promptOnChallenge=false 用于
      // 「验证通过后重抓」那一次，避免弹窗→重抓→再弹窗的死循环。
      final label = source?.bookSourceName ?? '';
      if (analyzed.method.toUpperCase() == 'POST') {
        return client.post(
          uri,
          body: _postBody(analyzed),
          headers: _postHeaders(analyzed),
          charset: analyzed.charset,
          label: label,
          promptOnChallenge: promptOnChallenge,
        );
      }
      return client.get(
        uri,
        charset: analyzed.charset,
        label: label,
        promptOnChallenge: promptOnChallenge,
      );
    }

    // 书源 concurrentRate：`"1000"`（最小间隔）或 `"3/1000"`（窗口内次数）。
    // 放在 send 外层而不是网络层，因为限速是「按书源」而不是「按 host」——
    // 同一 host 上挂着几十个书源时，按 host 限速会把无关书源互相拖慢。
    final gate = source == null
        ? null
        : _rateGates.gateOf(source.bookSourceUrl, source.concurrentRate);
    Future<HttpResponse> sendLimited() =>
        gate == null ? send() : gate.run(send);

    var response = await sendLimited();
    // 规则里的 `retry`：响应失败时额外重试几次（对齐 Kotlin newCallStrResponse）。
    // 连接层重试由 NetClient 自己做，这里补的是「拿到错误状态码」的情况。
    for (var i = 0; i < analyzed.retry && !response.isSuccess; i++) {
      response = await sendLimited();
    }
    return response;
  }

  // ---- 反爬 / 人机验证 -------------------------------------------------

  /// 打开宿主内置浏览器，等用户过验证，返回验证后的页面 HTML。
  ///
  /// 对齐 Kotlin `SourceVerificationHelp.getVerificationResult` +
  /// `WebViewModel.saveVerificationResult`：
  /// 1. 浏览器加载 [rawUrl]（带书源请求头，见 `browserSafeHeaders`）；
  /// 2. 用户过验证后宿主回填浏览器 cookie（含 HttpOnly 的 `cf_clearance`）与 UA；
  /// 3. [refetchAfterSuccess] 为真时用内核重新请求一次——比 `outerHTML` 干净，
  ///    也不会把浏览器的插件痕迹带进正文；
  /// 4. 重抓不成功（凭证只绑 IP、站点只有 `__cf_bm`）就退回浏览器渲染结果。
  ///
  /// 验证过程可能持续几十秒到几分钟，调用方（JS 脚本）会一直阻塞等待。
  Future<String> _verifyWithBrowser(
    BookSource source, {
    required String rawUrl,
    required String title,
    required String baseUrl,
    required Map<String, String> variables,
    bool refetchAfterSuccess = true,
  }) async {
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !uri.hasScheme) {
      throw LegadoException(ErrorCode.invalid, '验证地址非法: $rawUrl');
    }
    final handler = HostVerification.browser;
    if (handler == null) {
      throw const LegadoException(
        ErrorCode.unsupported,
        '当前宿主不支持内置浏览器验证（请用 App；CLI 无法完成人机验证）',
      );
    }

    final result = await handler(
      BrowserVerificationRequest(
        uri: uri,
        headers: browserSafeHeaders(_sourceHeaders(source)),
        title: title.trim().isEmpty ? source.bookSourceName : title.trim(),
        sourceKey: source.bookSourceUrl,
        refetchAfterSuccess: refetchAfterSuccess,
      ),
    );
    if (result == null || result.skipped) {
      throw const LegadoException(ErrorCode.invalid, '已取消验证');
    }

    // 合并写入，不整份替换：浏览器只新增 cf_clearance，登录态 cookie 必须留着。
    final cookie = result.cookie?.trim() ?? '';
    final finalUri = result.finalUrl ?? uri;
    if (cookie.isNotEmpty) {
      _net.cookies.importCookieHeader(finalUri, cookie);
    }
    final ua = result.userAgent?.trim() ?? '';
    if (ua.isNotEmpty) {
      _net.guard.state.setUserAgent(finalUri.host, ua);
    }
    await persistCookies();

    if (refetchAfterSuccess) {
      final refreshed = await _refetchAfterVerification(
        source,
        rawUrl: rawUrl,
        baseUrl: baseUrl,
        variables: variables,
      );
      if (refreshed.isNotEmpty) return refreshed;
    }

    final html = result.html ?? '';
    if (html.trim().isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '验证后没有拿到页面内容');
    }
    return html;
  }

  /// 验证通过后用正常 HTTP 链路重抓一次。
  ///
  /// 失败返回空串而不是抛异常：调用方会用浏览器 HTML 兜底，
  /// 「凭证不生效」不该让整条规则失败得莫名其妙。
  Future<String> _refetchAfterVerification(
    BookSource source, {
    required String rawUrl,
    required String baseUrl,
    required Map<String, String> variables,
  }) async {
    final effectiveBase = baseUrl.isEmpty ? source.bookSourceUrl : baseUrl;
    try {
      final analyzer = UrlRuleAnalyzer(
        _contextOf(
          source,
          baseUrl: effectiveBase,
          variables: variables,
          withJava: false,
        ),
      );
      final analyzed = await analyzer.analyze(rawUrl, baseUrl: effectiveBase);
      final response = await _request(
        analyzed,
        source: source,
        // 关键：重抓这一次不许再弹窗。
        promptOnChallenge: false,
      );
      if (!response.isSuccess) {
        _log.info('验证后重抓返回 HTTP ${response.statusCode}，使用浏览器结果');
        return '';
      }
      return response.text();
    } catch (e) {
      _log.info('验证后重抓失败，使用浏览器结果：$e');
      return '';
    }
  }

  /// 浏览器每加载完一页就回填一次 cookie（对齐原版 `WebViewActivity.onPageFinished`）。
  ///
  /// 为什么不等验证结束再回填：`java.startBrowser` 是「开个窗」语义，不等结果；
  /// 用户在窗口里登录完直接返回时，只有实时回填才留得住登录态。
  Future<void> importBrowserCookie(
    String url,
    String cookie, {
    String userAgent = '',
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw LegadoException(ErrorCode.invalid, '非法的验证地址: $url');
    }
    if (cookie.trim().isNotEmpty) {
      _net.cookies.importCookieHeader(uri, cookie);
    }
    if (userAgent.trim().isNotEmpty) {
      _net.guard.state.setUserAgent(uri.host, userAgent);
    }
    await persistCookies();
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
