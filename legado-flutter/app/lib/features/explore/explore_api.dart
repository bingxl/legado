import '../../core/bridge/legado_client.dart';

/// 发现域的控制面方法封装。
///
/// 对应原版 legado 的「发现」两块界面：
///   - `ui/main/explore/ExploreFragment`（一级：书源 + 分类）
///   - `ui/book/explore/ExploreShowActivity`（二级：某个分类下的书单）
///
/// 参数顺序来自 `legado methods Source`，改动前先用 CLI 核对。
class ExploreApi {
  ExploreApi._();

  static LegadoClient get _c => LegadoClient.instance;

  /// 列出开启了「发现」的书源。
  ///
  /// core 的过滤条件是「启用 + 开启发现 + 有 exploreUrl」，
  /// 与原版 `bookSourceDao.flowExplore()` 一致。
  static Future<List<Map<String, dynamic>>> listSources() {
    return _c.callList('Source.ListExploreSources');
  }

  /// 解析书源的发现分类。
  ///
  /// 返回 `ExploreKindView[]{title,url,paged}`。这一步可能要跑书源 JS、
  /// 发网络请求，耗时不短，原版也是展开时才异步加载。
  static Future<List<Map<String, dynamic>>> kinds(int sourceId) {
    return _c.callList('Source.ExploreKinds', [sourceId]);
  }

  /// 拉某个分类下的书单。[page] 从 1 开始。
  ///
  /// [url] 为空时 core 会回落到该源的首个分类。
  static Future<List<Map<String, dynamic>>> explore(
    int sourceId,
    String url,
    int page,
  ) {
    return _c.callList('Source.Explore', [sourceId, url, page]);
  }

  /// 把书源置顶（对应原版长按菜单的「置顶」）。
  static Future<void> moveTop(int id) {
    return _c.call('Source.MoveTop', [
      [id],
    ]);
  }

  /// 删除书源（对应原版长按菜单的「删除」）。
  static Future<void> delete(int id) {
    return _c.call('Source.Delete', [id]);
  }
}
