import 'package:xml/xml.dart' as xml;

import '../../domain/domain.dart';
import '../../kernel/errors.dart';
import '../../net/net.dart';
import '../../store/store.dart';

/// RSS 域：订阅源管理 + 文章拉取 / 已读 / 收藏。
///
/// `rssSources.sourceUrl` 与 `rssArticles.origin` 是业务主键，契约里的 int id
/// 一律映射到 SQLite rowid（文章是 `(origin, link)` 复合主键，只能靠 rowid）。
class RssService {
  RssService(this._daos) : _net = NetClient();

  final StoreDaos _daos;
  final NetClient _net;

  /// 未分组的订阅源 / 收藏都落在这个名字下，与原版列默认值一致。
  static const String defaultGroup = '默认分组';

  void close() => _net.close();

  // ---- 源 -------------------------------------------------------------

  List<Map<String, Object?>> listSources() {
    final unread = _daos.rssArticle.unreadCountByOrigin();
    return [
      for (final source in _daos.rssSource.all) _sourceView(source, unread[source.sourceUrl] ?? 0),
    ];
  }

  /// [input] 是单参数对象；`enabled` 省略表示不改。
  Map<String, Object?> saveSource(Map<String, Object?> input) {
    final id = _intOf(input['id']);
    final url = _textOf(input['url']).trim();
    final name = _textOf(input['name']).trim();
    if (url.isEmpty || name.isEmpty) {
      throw const LegadoException(ErrorCode.invalid, '订阅源需要 name 与 url');
    }
    final existing = id > 0 ? _sourceById(id) : _daos.rssSource.getByKey(url);
    if (id > 0 && existing == null) {
      throw LegadoException(ErrorCode.notFound, '订阅源不存在: $id');
    }
    final source = existing ?? RssSource();
    final oldUrl = source.sourceUrl;
    source
      ..sourceUrl = url
      ..sourceName = name
      ..sourceGroup = _textOf(input['group'])
      ..customOrder = _intOf(input['sortOrder'], fallback: source.customOrder);
    if (input.containsKey('enabled')) {
      source.enabled = _boolOf(input['enabled'], fallback: source.enabled);
    }
    if (existing == null) {
      _daos.rssSource.insert(source);
    } else if (oldUrl != url) {
      _daos.rssSource.deleteByKey(oldUrl);
      _daos.rssArticle.updateOrigin(url, oldUrl);
      _daos.rssStar.updateOrigin(url, oldUrl);
      _daos.rssSource.insert(source);
    } else {
      _daos.rssSource.update(source);
    }
    final unread = _daos.rssArticle.unreadCountByOrigin();
    return _sourceView(source, unread[url] ?? 0);
  }

  void deleteSource(int id) {
    final source = _requireSource(id);
    _daos.rssSource.delete(source);
    _daos.rssArticle.deleteByOrigin(source.sourceUrl);
    _daos.rssStar.deleteByOrigin(source.sourceUrl);
  }

  void setSourceEnabled(int id, bool enabled) =>
      _daos.rssSource.enable(_requireSource(id).sourceUrl, enabled);

  // ---- 文章 -----------------------------------------------------------

  List<Map<String, Object?>> listArticles(
    int sourceId,
    bool onlyUnread,
    int offset,
    int limit,
  ) {
    final origin = sourceId > 0 ? _requireSource(sourceId).sourceUrl : '';
    final safeOffset = offset < 0 ? 0 : offset;
    final safeLimit = limit <= 0 ? 200 : (limit > 1000 ? 1000 : limit);
    return [
      for (final (rowId, article) in _daos.rssArticle.listWithRowId(
        origin: origin,
        onlyUnread: onlyUnread,
        offset: safeOffset,
        limit: safeLimit,
      ))
        _articleView(rowId, article),
    ];
  }

  /// 刷新订阅；`sourceId=0` 刷新全部启用源。单源失败不影响其它源。
  Future<Map<String, Object?>> refresh(int sourceId) async {
    final sources = sourceId > 0
        ? [_requireSource(sourceId)]
        : _daos.rssSource.all.where((source) => source.enabled).toList();
    var added = 0;
    var updated = 0;
    var skipped = 0;
    final errors = <String>[];

    for (final source in sources) {
      try {
        final response = await _net.get(Uri.parse(source.sourceUrl));
        if (!response.isSuccess) {
          errors.add('${source.sourceName}: HTTP ${response.statusCode}');
          continue;
        }
        final items = _parseFeed(response.text());
        if (items.isEmpty) {
          errors.add('${source.sourceName}: 没有解析出文章');
          continue;
        }
        // 原版 `RssArticlesViewModel.order` 以当前毫秒时间戳为基数递减，
        // 每次刷新都从「现在」重新起算 —— 直接用 `items.length - i` 会让
        // 新一轮文章排到旧文章下面（序号从 0 重来），列表顺序越刷越乱。
        var order = DateTime.now().millisecondsSinceEpoch;
        // 空分组必须规范成「默认分组」：原版 `RssArticle.group` 的列默认值就是它，
        // 存成空串会让「默认分组」这个 tab 永远查不到东西。
        final rawGroup = (source.sourceGroup ?? '').trim();
        final group = rawGroup.isEmpty ? defaultGroup : rawGroup;
        for (final item in items) {
          final link = item['link'] ?? '';
          if (link.isEmpty) {
            skipped++;
            continue;
          }
          final existing = _daos.rssArticle.get(source.sourceUrl, link);
          final article = RssArticle(
            origin: source.sourceUrl,
            sort: source.sourceName,
            title: item['title'] ?? link,
            order: order--,
            link: link,
            pubDate: item['pubDate'],
            description: item['description'],
            content: item['content'],
            image: item['image'],
            group: group,
            read: existing?.read ?? false,
            variable: existing?.variable,
          );
          if (existing == null) {
            _daos.rssArticle.append(article);
            added++;
          } else {
            _daos.rssArticle.update(article);
            updated++;
          }
        }
        source.lastUpdateTime = DateTime.now().millisecondsSinceEpoch;
        _daos.rssSource.update(source);
      } on Object catch (e) {
        errors.add('${source.sourceName}: $e');
      }
    }
    return <String, Object?>{
      'sourceId': sourceId,
      'sources': sources.length,
      'added': added,
      'updated': updated,
      'skipped': skipped,
      'errors': errors,
    };
  }

  void markRead(int id, bool read) {
    final entry = _requireArticle(id);
    final article = entry.$2..read = read;
    _daos.rssArticle.update(article);
  }

  /// 切换收藏，返回切换后的状态。
  bool favorite(int id) {
    final entry = _requireArticle(id);
    final article = entry.$2;
    final star = _daos.rssStar.get(article.origin, article.link);
    if (star == null) {
      _daos.rssStar.insert(RssStar(
        origin: article.origin,
        sort: article.sort,
        title: article.title,
        starTime: DateTime.now().millisecondsSinceEpoch,
        link: article.link,
        pubDate: article.pubDate,
        description: article.description,
        content: article.content,
        image: article.image,
        group: article.group,
        variable: article.variable,
      ));
      return true;
    }
    _daos.rssStar.deleteOne(article.origin, article.link);
    return false;
  }

  /// 收藏列表，按收藏时间倒序（原版 `RssStarDao.all` 的排序）。
  ///
  /// [group] 为空表示全部收藏；非空时只返回该分组（原版 `flowByGroup`）。
  ///
  /// 每条都回填**真实**的文章 rowid：收藏表主键是 `(origin, link)`，
  /// 没有 int id 就调不了 `Rss.Article.Favorite`（星标点了没反应）。
  /// 文章行确实不存在时 id 为 0，此时取消收藏走 `Rss.Favorite.Remove`。
  List<Map<String, Object?>> listFavorites({String group = ''}) {
    final stars = group.isEmpty
        ? _daos.rssStar.all
        // 历史数据里默认分组的 group 可能是空串（旧版写入），一起并进来。
        : group == defaultGroup
            ? [..._daos.rssStar.byGroup(defaultGroup), ..._daos.rssStar.byGroup('')]
            : _daos.rssStar.byGroup(group);
    return [for (final star in stars) _starView(star)];
  }

  /// 收藏夹的分组名（原版 `flowGroups`）；空串归一到默认分组并去重。
  List<String> favoriteGroups() {
    final out = <String>{};
    for (final group in _daos.rssStar.groups()) {
      out.add(group.trim().isEmpty ? defaultGroup : group);
    }
    final list = out.toList()..sort();
    return list;
  }

  /// 按 `(origin, link)` 取消收藏；返回取消后仍存在的收藏数。
  void removeFavorite(String origin, String link) {
    _daos.rssStar.deleteOne(origin, link);
  }

  Map<String, Object?> _starView(RssStar star) => <String, Object?>{
        'id': _daos.rssArticle.rowIdOf(star.origin, star.link) ?? 0,
        // origin 是取消收藏的备用键（文章行被清理时 id 为 0）。
        'origin': star.origin,
        'sourceId': _sourceRowId(star.origin) ?? 0,
        'sourceName': star.sort,
        'title': star.title,
        'link': star.link,
        'description': star.description,
        'content': star.content,
        'author': '',
        'pubDate': _pubDateSeconds(star.pubDate),
        'read': true,
        'favorite': true,
        'group': star.group.trim().isEmpty ? defaultGroup : star.group,
        'createdAt': star.pubDate ?? '',
      };

  Map<String, int> unreadCount() {
    final byUrl = <String, int>{};
    for (final source in _daos.rssSource.all) {
      final rowId = _sourceRowId(source.sourceUrl);
      if (rowId != null) byUrl[source.sourceUrl] = rowId;
    }
    final out = <String, int>{};
    for (final entry in _daos.rssArticle.unreadCountByOrigin().entries) {
      final id = byUrl[entry.key];
      if (id != null) out['$id'] = entry.value;
    }
    return out;
  }

  // ---- helpers --------------------------------------------------------

  RssSource _requireSource(int id) {
    final source = _sourceById(id);
    if (source == null) {
      throw LegadoException(ErrorCode.notFound, '订阅源不存在: $id');
    }
    return source;
  }

  RssSource? _sourceById(int id) {
    for (final source in _daos.rssSource.all) {
      if (_sourceRowId(source.sourceUrl) == id) return source;
    }
    return null;
  }

  int? _sourceRowId(String url) {
    final rows = _daos.rssSource.all;
    if (rows.isEmpty) return null;
    // rssSources 以 sourceUrl 为主键，rowid 稳定；直接查一次 rowid。
    final found = _daos.db.select(
      'select rowid as id from rssSources where sourceUrl = ?',
      [url],
    );
    return found.isEmpty ? null : (found.first['id'] as num?)?.toInt();
  }

  (int, RssArticle) _requireArticle(int id) {
    final entry = _daos.rssArticle.getByRowId(id);
    if (entry == null) {
      throw LegadoException(ErrorCode.notFound, '文章不存在: $id');
    }
    return entry;
  }

  Map<String, Object?> _sourceView(RssSource source, int unread) =>
      <String, Object?>{
        'id': _sourceRowId(source.sourceUrl) ?? 0,
        'name': source.sourceName,
        'url': source.sourceUrl,
        'group': source.sourceGroup ?? '',
        'enabled': source.enabled,
        'sortOrder': source.customOrder,
        'unreadCount': unread,
        'createdAt': source.lastUpdateTime > 0
            ? DateTime.fromMillisecondsSinceEpoch(source.lastUpdateTime, isUtc: true)
                .toIso8601String()
            : null,
        'updatedAt': source.lastUpdateTime > 0
            ? DateTime.fromMillisecondsSinceEpoch(source.lastUpdateTime, isUtc: true)
                .toIso8601String()
            : null,
      };

  Map<String, Object?> _articleView(int rowId, RssArticle article) {
    final sourceId = _sourceRowId(article.origin);
    return <String, Object?>{
      'id': rowId,
      'origin': article.origin,
      'sourceId': sourceId ?? 0,
      'sourceName': article.sort,
      'title': article.title,
      'link': article.link,
      'description': article.description,
      'content': article.content,
      'author': '',
      // 订阅源的 pubDate 是原始文本（RFC822 / ISO8601），UI 要的是 Unix 秒：
      // 直接透传字符串会让 `rssInt()` 解析失败 → 列表里时间恒为空。
      'pubDate': _pubDateSeconds(article.pubDate),
      'read': article.read,
      'favorite': rowId > 0 ? _isFavorite(rowId) : true,
      'group': article.group,
      'createdAt': article.pubDate ?? '',
    };
  }

  /// 订阅源时间文本 → Unix 秒；认不出来就返回 0（UI 会隐藏时间）。
  ///
  /// 顺序有讲究：先按 ISO8601（Atom 的 `published`/`updated`，`DateTime.tryParse`
  /// 直接吃），再按 RFC822（RSS 2.0 主流写法，Dart 没有内置解析器，手动兜），
  /// 最后当纯数字（秒或毫秒时间戳）。
  static int _pubDateSeconds(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return 0;
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso.millisecondsSinceEpoch ~/ 1000;
    final rfc = _parseRfc822(text);
    if (rfc > 0) return rfc ~/ 1000;
    final numeric = int.tryParse(text);
    if (numeric != null && numeric > 0) {
      // 兼容毫秒时间戳；秒级时间戳不会超过 1e11。
      return numeric > 100000000000 ? numeric ~/ 1000 : numeric;
    }
    return 0;
  }

  /// RFC822 / RFC1123：`Tue, 02 Jan 2024 15:04:05 +0800`（时区可省）。
  static final RegExp _rfc822 = RegExp(
    r'(?:^|,\s*)(\d{1,2})\s+([A-Za-z]{3})\s+(\d{2,4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?'
    r'\s*(?:(GMT|UTC|UT)|([+-])(\d{2})(\d{2}))?',
  );

  static const List<String> _monthAbbr = [
    'jan', 'feb', 'mar', 'apr', 'may', 'jun',
    'jul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  static int _parseRfc822(String value) {
    final m = _rfc822.firstMatch(value);
    if (m == null) return 0;
    final month = _monthAbbr.indexOf((m.group(2) ?? '').toLowerCase()) + 1;
    if (month == 0) return 0;
    var year = int.tryParse(m.group(3) ?? '') ?? 0;
    if (year == 0) return 0;
    // 两位年份：按 RFC822 惯例落在 1900/2000 世代，订阅源基本都是 2000+。
    if (year < 100) year += year < 50 ? 2000 : 1900;
    final offsetMinutes = switch (m.group(8)) {
      '+' => (int.tryParse(m.group(9) ?? '') ?? 0) * 60 +
          (int.tryParse(m.group(10) ?? '') ?? 0),
      '-' => -((int.tryParse(m.group(9) ?? '') ?? 0) * 60 +
          (int.tryParse(m.group(10) ?? '') ?? 0)),
      // GMT/UTC/UT 与「没写时区」都按 UTC 处理（比按本地时区安全）。
      _ => 0,
    };
    final utc = DateTime.utc(
      year,
      month,
      int.tryParse(m.group(1) ?? '') ?? 1,
      int.tryParse(m.group(4) ?? '') ?? 0,
      int.tryParse(m.group(5) ?? '') ?? 0,
      int.tryParse(m.group(6) ?? '') ?? 0,
    );
    return utc.subtract(Duration(minutes: offsetMinutes)).millisecondsSinceEpoch;
  }

  bool _isFavorite(int rowId) {
    final entry = _daos.rssArticle.getByRowId(rowId);
    if (entry == null) return false;
    return _daos.rssStar.get(entry.$2.origin, entry.$2.link) != null;
  }

  int _intOf(Object? value, {int fallback = 0}) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  String _textOf(Object? value) =>
      value == null ? '' : (value is String ? value : '$value');

  bool _boolOf(Object? value, {required bool fallback}) {
    if (value == null) return fallback;
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      return switch (value.toLowerCase()) {
        'true' || '1' || 'yes' => true,
        _ => false,
      };
    }
    return fallback;
  }
}

/// 解析 RSS 2.0 / Atom / RDF 的最小公共子集。
///
/// 用 `xml` 包而不是正则：CDATA、命名空间、实体转义都会让正则解析在真实
/// 订阅源上频繁出错；这里只取列表页需要的几个字段，不做完整规范化。
List<Map<String, String?>> _parseFeed(String text) {
  final document = xml.XmlDocument.parse(text);
  final items = <xml.XmlElement>[
    ...document.findAllElements('item'),
    ...document.findAllElements('entry'),
  ];
  final out = <Map<String, String?>>[];
  for (final item in items) {
    String? pick(String localName) {
      for (final child in item.childElements) {
        if (child.name.local == localName) {
          final value = child.innerText.trim();
          if (value.isNotEmpty) return value;
        }
      }
      return null;
    }

    var link = pick('link');
    if (link == null || link.isEmpty) {
      for (final child in item.childElements) {
        if (child.name.local == 'link' &&
            child.getAttribute('rel') == 'alternate') {
          link = child.getAttribute('href');
          break;
        }
      }
    }
    link ??= pick('guid');
    out.add(<String, String?>{
      'title': pick('title'),
      'link': link,
      'pubDate': pick('pubDate') ?? pick('published') ?? pick('updated'),
      'description': pick('description') ?? pick('summary') ?? pick('content'),
      'content': pick('encoded') ?? pick('content'),
      'image': pick('image'),
    });
  }
  return out;
}
