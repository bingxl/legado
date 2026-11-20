import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../reader/reader_module.dart';
import '../shelf/shelf_module.dart';
import '../service_args.dart';
import 'cache_service.dart';

/// 缓存域模块：10 个方法。
class CacheModule extends CoreModule {
  CacheService? _service;

  @override
  String get name => 'cache';

  @override
  List<String> get dependsOn => const ['store', 'shelf', 'reader'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    final reader = ReaderModule.instance;
    final shelf = ShelfModule.instance;
    if (store == null || reader == null || shelf == null) {
      throw StateError('cache 依赖 store/shelf/reader');
    }
    final service = CacheService(
      daos: store.daos,
      reader: reader.service,
      shelf: shelf.service,
      homeDir: ctx.homeDir,
    );
    _service = service;

    registry.method(
      'Cache.Start',
      (args) async {
        final rawIndexes = (arg(args, 2) as List?) ?? const <Object?>[];
        return service
            .start(
              asInt(arg(args, 0)),
              asText(arg(args, 1)),
              [for (final index in rawIndexes) asInt(index)],
            )
            .toJson();
      },
      params: const ['bookID int', 'scope string', 'indexes int[]'],
      doc: 'scope ∈ all/remaining/missing/chapters；立即回执，后台执行',
    );

    registry.method(
      'Cache.Cancel',
      (args) async {
        service.cancel(asInt(arg(args, 0)));
        return null;
      },
      params: const ['bookID int'],
      doc: '幂等；没有任务也成功',
    );

    registry.method('Cache.Jobs', (args) async => service.jobs(),
        doc: '含已结束任务');

    registry.method('Cache.Stats', (args) async => service.stats(),
        doc: '{books, chapters, size, running}');

    registry.method('Cache.Books', (args) async => service.books(),
        doc: '有缓存的书，按最近缓存时间倒序');

    registry.method(
      'Cache.Chapters',
      (args) async => service.chapters(asInt(arg(args, 0))),
      params: const ['bookID int'],
    );

    registry.method(
      'Cache.Status',
      (args) async => service.status(asInt(arg(args, 0))),
      params: const ['bookID int'],
    );

    registry.method(
      'Cache.Delete',
      (args) async {
        final rawIndexes = (arg(args, 1) as List?) ?? const <Object?>[];
        service.delete(
          asInt(arg(args, 0)),
          [for (final index in rawIndexes) asInt(index)],
        );
        return null;
      },
      params: const ['bookID int', 'indexes int[]'],
      doc: 'indexes 空时什么也不做',
    );

    registry.method(
      'Cache.PurgeBook',
      (args) async {
        service.purgeBook(asInt(arg(args, 0)));
        return null;
      },
      params: const ['bookID int'],
      doc: '清 DB + 磁盘图片，并停任务',
    );

    registry.method(
      'Cache.Clear',
      (args) async {
        service.clear();
        return null;
      },
      doc: '清全部缓存与任务',
    );
  }

  @override
  Future<void> close() async {
    final service = _service;
    _service = null;
    await service?.close();
  }
}
