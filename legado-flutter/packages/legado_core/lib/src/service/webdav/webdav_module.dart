import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../library/library_service.dart';
import '../shelf/shelf_module.dart';
import '../service_args.dart';
import 'webdav_service.dart';

/// WebDAV 域模块：11 个方法（见 docs/方法契约表.md）。
class WebDAVModule extends CoreModule {
  WebDAVService? _service;

  @override
  String get name => 'webdav';

  @override
  List<String> get dependsOn => const ['store', 'shelf', 'library'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    final shelf = ShelfModule.instance;
    if (store == null || shelf == null) {
      throw StateError('webdav 依赖 store / shelf');
    }
    final service = WebDAVService(
      daos: store.daos,
      library: LibraryService(
        daos: store.daos,
        shelf: shelf.service,
        homeDir: ctx.homeDir,
      ),
      homeDir: ctx.homeDir,
    );
    _service = service;

    registry.method(
      'WebDAV.GetConfig',
      (args) async => service.getConfig().toJson(),
      doc: '密码永不返回，只给 hasPassword',
    );

    registry.method(
      'WebDAV.SaveConfig',
      (args) async => (await service.saveConfig(
        asText(arg(args, 0)),
        asText(arg(args, 1)),
        asText(arg(args, 2)),
        asText(arg(args, 3)),
        asBool(arg(args, 4)),
      )).toJson(),
      params: const [
        'url string', 'username string', 'password string',
        'rootPath string', 'autoSync bool',
      ],
      doc: 'password="" 保持原密码',
    );

    registry.method(
      'WebDAV.Test',
      (args) async {
        await service.test();
        return null;
      },
      doc: '列根目录成功即通过',
    );

    registry.method(
      'WebDAV.List',
      (args) async => service.list(asText(arg(args, 0))),
      params: const ['relPath string'],
      doc: 'path 一律相对工作根；relPath="" 表示根',
    );

    registry.method(
      'WebDAV.UploadBackup',
      (args) async => (await service.uploadBackup()).toJson(),
      doc: 'sqlite3 backup API；立即回执进度',
    );

    registry.method(
      'WebDAV.BackupStatus',
      (args) async => service.backupStatus().toJson(),
      doc: '查询备份同步进度',
    );

    registry.method(
      'WebDAV.DownloadBackup',
      (args) async => service.downloadBackup(
        asText(arg(args, 0)),
        asText(arg(args, 1)),
      ),
      params: const ['remotePath string', 'localDir string'],
      doc: '落盘到 localDir，不替换运行中的数据库',
    );

    registry.method(
      'WebDAV.Delete',
      (args) async {
        await service.delete(asText(arg(args, 0)));
        return null;
      },
      params: const ['relPath string'],
    );

    registry.method(
      'WebDAV.ScanBooks',
      (args) async => service.scanBooks(asText(arg(args, 0))),
      params: const ['relPath string'],
      doc: '递归扫描书籍文件；relPath="" 表示根',
    );

    registry.method(
      'WebDAV.StartBookImport',
      (args) async {
        final rawPaths = (arg(args, 0) as List?) ?? const <Object?>[];
        return service
            .startBookImport(
              [for (final path in rawPaths) asText(path)],
              asInt(arg(args, 1)),
            )
            .toJson();
      },
      params: const ['relPaths string[]', 'groupID int'],
      doc: '立即回执，后台下载 + 导入',
    );

    registry.method(
      'WebDAV.ImportStatus',
      (args) async => service.importStatus().toJson(),
      doc: '从未导入返回 state=idle',
    );

    registry.method(
      'WebDAV.CancelBookImport',
      (args) async {
        service.cancelBookImport();
        return null;
      },
      doc: '半成品 .part 一并删除',
    );
  }

  @override
  Future<void> close() async {
    final service = _service;
    _service = null;
    await service?.close();
  }
}
