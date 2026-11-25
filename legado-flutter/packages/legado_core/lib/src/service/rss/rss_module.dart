import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../service_args.dart';
import 'rss_service.dart';

/// RSS 域模块：12 个方法。
class RssModule extends CoreModule {
  RssService? _service;

  @override
  String get name => 'rss';

  @override
  List<String> get dependsOn => const ['store'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) throw StateError('rss 依赖 store');
    final service = RssService(store.daos);
    _service = service;

    registry.method('Rss.Source.List', (args) async => service.listSources());
    registry.method(
      'Rss.Source.Save',
      (args) async => service.saveSource(asMap(arg(args, 0))),
      params: const ['SourceInput Map'],
      doc: '单参数对象；enabled 省略表示不改',
    );
    registry.method(
      'Rss.Source.Delete',
      (args) async {
        service.deleteSource(asInt(arg(args, 0)));
        return null;
      },
      params: const ['id int'],
    );
    registry.method(
      'Rss.Source.SetEnabled',
      (args) async {
        service.setSourceEnabled(asInt(arg(args, 0)), asBool(arg(args, 1)));
        return null;
      },
      params: const ['id int', 'enabled bool'],
    );

    registry.method(
      'Rss.Article.List',
      (args) async => service.listArticles(
        asInt(arg(args, 0)),
        asBool(arg(args, 1)),
        asInt(arg(args, 2)),
        asInt(arg(args, 3)),
      ),
      params: const ['sourceId int', 'onlyUnread bool', 'offset int', 'limit int'],
      doc: 'offset 在 limit 前；sourceId=0 全部',
    );
    registry.method(
      'Rss.Article.Refresh',
      (args) async => service.refresh(asInt(arg(args, 0))),
      params: const ['sourceId int'],
      doc: 'sourceId=0 全部启用源；单源失败记 errors',
    );
    registry.method(
      'Rss.Article.MarkRead',
      (args) async {
        service.markRead(asInt(arg(args, 0)), asBool(arg(args, 1)));
        return null;
      },
      params: const ['id int', 'read bool'],
    );
    registry.method(
      'Rss.Article.Favorite',
      (args) async => service.favorite(asInt(arg(args, 0))),
      params: const ['id int'],
      doc: 'toggle，返回切换后的状态',
    );
    registry.method(
      'Rss.Favorite.List',
      (args) async => service.listFavorites(
        group: asText(arg(args, 0)),
      ),
      params: const ['group string?'],
      doc: 'group 省略或空串表示全部；按收藏时间倒序',
    );
    registry.method(
      'Rss.Favorite.Groups',
      (args) async => service.favoriteGroups(),
      doc: '收藏夹用到的分组名，升序',
    );
    registry.method(
      'Rss.Favorite.Remove',
      (args) async {
        service.removeFavorite(asText(arg(args, 0)), asText(arg(args, 1)));
        return null;
      },
      params: const ['origin string', 'link string'],
      doc: '按 (origin, link) 取消收藏；文章行已清理、id 为 0 时用它',
    );
    registry.method(
      'Rss.Unread.Count',
      (args) async => service.unreadCount(),
      doc: 'key 是 sourceId 的十进制字符串',
    );
  }

  @override
  Future<void> close() async {
    final service = _service;
    _service = null;
    service?.close();
  }
}
