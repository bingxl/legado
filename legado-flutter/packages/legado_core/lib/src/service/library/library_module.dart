import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../shelf/shelf_module.dart';
import '../service_args.dart';
import 'library_service.dart';

/// 本地书导入 / 导出域。
class LibraryModule extends CoreModule {
  @override
  String get name => 'library';

  @override
  List<String> get dependsOn => const ['store', 'shelf'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    final shelf = ShelfModule.instance;
    if (store == null || shelf == null) {
      throw StateError('library 依赖 store 与 shelf');
    }
    final service = LibraryService(
      daos: store.daos,
      shelf: shelf.service,
      homeDir: ctx.homeDir,
    );

    registry.method(
      'Library.ImportLocalFiles',
      (args) async {
        final paths = (arg(args, 0) as List?)?.cast<Object?>() ?? const <Object?>[];
        return (await service.importLocalFiles(
          [for (final path in paths) asText(path)],
          asInt(arg(args, 1)),
        )).toJson();
      },
      params: const ['paths string[]', 'groupID int'],
      doc: '同路径重复导入走更新；逐文件记录失败原因',
    );

    registry.method(
      'Library.ExportBook',
      (args) async => (await service.exportBook(
        asInt(arg(args, 0)),
        asText(arg(args, 1)),
        asText(arg(args, 2)),
      )).toJson(),
      params: const ['bookID int', 'format string', 'destPath string'],
      doc: '当前仅 txt；其它格式抛 NOT_IMPLEMENTED',
    );
  }
}
