import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../service_args.dart';
import '../shelf/shelf_module.dart';
import 'source_fetch_service.dart';

/// 书源抓取链路模块：发现 / 搜索 / 试读入库。
///
/// 刻意与 [SourceModule] 分开：本地管理只需要 store，抓取还要 shelf，
/// 合并后会逼着「导入书源」这种纯本地操作也去初始化书架域。
/// 方法名仍统一用 `Source.` 前缀，UI 与 CLI 不感知模块边界。
class SourceFetchModule extends CoreModule {
  /// 供 Reader 等域复用同一个 service 实例。
  ///
  /// 网络书正文抓取要复用这里的抓取链路（书源规则 + 网络层），
  /// 另起一份实现必然出现「同一本书两种正文」的问题。
  static SourceFetchModule? instance;

  SourceFetchService? _fetch;

  @override
  String get name => 'sourcefetch';

  @override
  List<String> get dependsOn => const ['store', 'source', 'shelf'];

  /// 抓取服务实例（模块已 register 时可用）。
  SourceFetchService get service {
    final fetch = _fetch;
    if (fetch == null) {
      throw StateError('sourcefetch 模块尚未 register');
    }
    return fetch;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) throw StateError('source 抓取链路依赖 store');
    final shelf = ShelfModule.instance;
    if (shelf == null) throw StateError('source 抓取链路依赖 shelf');
    final fetch = SourceFetchService(daos: store.daos, shelf: shelf.service);
    _fetch = fetch;
    instance = this;

    // ---- 发现与搜索（规则 + 网络）----
    registry.method(
      'Source.ListExploreSources',
      (args) async => [
        for (final view in fetch.listExploreSources()) view.toJson(),
      ],
      doc: '启用 + 开启发现 + 有 exploreUrl',
    );
    registry.method(
      'Source.ExploreKinds',
      (args) async => [
        for (final view in await fetch.exploreKinds(asInt(arg(args, 0))))
          view.toJson(),
      ],
      params: const ['sourceID int'],
      doc: '纯本地解析 exploreUrl',
    );
    registry.method(
      'Source.Explore',
      (args) async => [
        for (final view in await fetch.explore(
          asInt(arg(args, 0)),
          asText(arg(args, 1)),
          asInt(arg(args, 2)),
        ))
          view.toJson(),
      ],
      params: const ['sourceID int', 'url string', 'page int'],
    );
    registry.method(
      'Source.Search',
      (args) async => [
        for (final view in await fetch.search(
          asInt(arg(args, 0)),
          asText(arg(args, 1)),
          asInt(arg(args, 2)),
        ))
          view.toJson(),
      ],
      params: const ['sourceID int', 'keyword string', 'page int'],
    );
    registry.method(
      'Source.SearchAll',
      (args) async => [
        for (final view in await fetch.searchAll(
          asText(arg(args, 0)),
          asInt(arg(args, 1)),
        ))
          view.toJson(),
      ],
      params: const ['keyword string', 'page int'],
    );
    registry.method(
      'Source.PreviewBook',
      (args) async => fetch.upsertBook(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
        asText(arg(args, 2)),
        asText(arg(args, 3)),
        asText(arg(args, 4)),
        0,
        false,
        asText(arg(args, 5)),
      ),
      params: const [
        'sourceID int',
        'bookURL string',
        'name string',
        'author string',
        'variable string',
        'coverURL string?',
      ],
      doc: '入库但 inShelf=false',
    );
    registry.method(
      'Source.AddBookByUrl',
      (args) async => fetch.addBookByUrl(
        asText(arg(args, 0)),
        asInt(arg(args, 1)),
      ),
      params: const ['urls string', 'groupID int'],
      doc: '多行 URL；按域名/bookUrlPattern 匹配书源后解析入库',
    );
    registry.method(
      'Source.AddToShelf',
      (args) async => fetch.upsertBook(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
        asText(arg(args, 2)),
        asText(arg(args, 3)),
        asText(arg(args, 4)),
        asInt(arg(args, 5)),
        true,
      ),
      params: const [
        'sourceID int',
        'bookURL string',
        'name string',
        'author string',
        'variable string',
        'groupID int',
      ],
    );
  }

  @override
  Future<void> close() async {
    final fetch = _fetch;
    _fetch = null;
    if (identical(instance, this)) instance = null;
    fetch?.close();
  }
}
