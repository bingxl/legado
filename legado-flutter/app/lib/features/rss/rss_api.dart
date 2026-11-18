import '../../core/bridge/legado_client.dart';

/// RSS 域的控制面方法封装。
///
/// 只做「方法名 + 位置参数顺序」的映射；订阅解析、去重、入库全在 core。
/// 参数顺序用 `legado methods Rss` 核对过：
///   Rss.Article.List(sourceId, onlyUnread, offset, limit)
///   Rss.Source.Save({id,name,url,group,enabled}) —— 唯一一个对象参数
class RssApi {
  RssApi._();

  static LegadoClient get _c => LegadoClient.instance;

  // ── 订阅源 ──────────────────────────────────────────────

  /// 订阅源列表，已带上每个源的未读数（unreadCount）。
  static Future<List<Map<String, dynamic>>> listSources() {
    return _c.callList('Rss.Source.List');
  }

  /// 新增或更新。id 为 0 表示新增；name 留空时 core 会用地址补。
  static Future<Map<String, dynamic>> saveSource({
    required int id,
    required String name,
    required String url,
    required String group,
    required bool enabled,
  }) async {
    final data = await _c.call('Rss.Source.Save', [
      {
        'id': id,
        'name': name,
        'url': url,
        'group': group,
        'enabled': enabled,
      },
    ]);
    return _map(data);
  }

  static Future<void> deleteSource(int id) =>
      _c.call('Rss.Source.Delete', [id]);

  static Future<void> setSourceEnabled(int id, bool enabled) =>
      _c.call('Rss.Source.SetEnabled', [id, enabled]);

  // ── 文章 ────────────────────────────────────────────────

  /// 拉取文章。sourceId 为 0 表示全部源。
  ///
  /// 分页是 offset/limit：core 不返回总数，只能靠「空页」判断到底。
  static Future<List<Map<String, dynamic>>> listArticles({
    required int sourceId,
    required bool unreadOnly,
    required int offset,
    required int limit,
  }) {
    return _c.callList('Rss.Article.List', [
      sourceId,
      unreadOnly,
      offset,
      limit,
    ]);
  }

  /// 刷新订阅。sourceId 为 0 时 core 会刷新全部启用的源。
  ///
  /// 返回 {sourceId,sources,added,updated,skipped,errors}；
  /// errors 是逐源失败原因，单个源失败不影响其他源。
  static Future<Map<String, dynamic>> refreshArticles(int sourceId) async {
    final data = await _c.call('Rss.Article.Refresh', [sourceId]);
    return _map(data);
  }

  static Future<void> markRead(int id, bool read) =>
      _c.call('Rss.Article.MarkRead', [id, read]);

  /// 切换收藏，返回切换后的状态（core 侧就是 toggle 语义）。
  static Future<bool> toggleFavorite(int id) async {
    final data = await _c.call('Rss.Article.Favorite', [id]);
    return data == true;
  }

  static Future<List<Map<String, dynamic>>> listFavorites() {
    return _c.callList('Rss.Favorite.List');
  }

  static Map<String, dynamic> _map(dynamic data) {
    if (data is Map) return data.cast<String, dynamic>();
    return <String, dynamic>{};
  }
}

/// 从 dto 里安全取整数字段（后端可能给 int、num 或字符串）。
int rssInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
