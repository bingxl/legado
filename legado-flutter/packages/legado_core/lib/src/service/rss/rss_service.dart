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
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
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
            order: items.length - i,
            link: link,
            pubDate: item['pubDate'],
            description: item['description'],
            content: item['content'],
            image: item['image'],
            group: source.sourceGroup ?? '默认分组',
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

  List<Map<String, Object?>> listFavorites() {
    final out = <Map<String, Object?>>[];
    for (final star in _daos.rssStar.byGroup('')) {
      out.add(_articleView(0, RssArticle(
            origin: star.origin,
            sort: star.sort,
            title: star.title,
            link: star.link,
            pubDate: star.pubDate,
            description: star.description,
            content: star.content,
            image: star.image,
            group: star.group,
            read: true,
            variable: star.variable,
          )));
    }
    // byGroup('') 只命中默认分组；把其它分组也补进来。
    for (final group in _daos.rssStar.groups()) {
      if (group == '默认分组') continue;
      for (final star in _daos.rssStar.byGroup(group)) {
        out.add(_articleView(0, RssArticle(
              origin: star.origin,
              sort: star.sort,
              title: star.title,
              link: star.link,
              pubDate: star.pubDate,
              description: star.description,
              content: star.content,
              image: star.image,
              group: star.group,
              read: true,
              variable: star.variable,
            )));
      }
    }
    return out;
  }

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
      'sourceId': sourceId ?? 0,
      'sourceName': article.sort,
      'title': article.title,
      'link': article.link,
      'description': article.description,
      'content': article.content,
      'author': '',
      'pubDate': article.pubDate,
      'read': article.read,
      'favorite': rowId > 0 ? _isFavorite(rowId) : true,
      'createdAt': article.pubDate ?? '',
    };
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
