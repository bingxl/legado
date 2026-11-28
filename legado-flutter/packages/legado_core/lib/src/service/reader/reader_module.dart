import '../../kernel/errors.dart';
import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../cache/image_cache_service.dart';
import '../setting/settings_module.dart';
import '../shelf/shelf_module.dart';
import '../source/source_fetch_module.dart';
import 'reader_service.dart';

/// 阅读器域模块。
///
/// 依赖 shelf 是为了复用进度读写：Reader 的 `GetProgress`/`SaveProgress`
/// 与 Shelf 的同名方法参数、语义、落点完全一致，不能各自实现一份。
class ReaderModule extends CoreModule {
  /// 供 Cache 等后续域复用同一个 service 实例。
  static ReaderModule? instance;

  ReaderService? _service;
  ImageCacheService? _images;

  /// 供 Cache 域复用同一个图片缓存实例（并发闸门 + cookie 池共享）。
  ImageCacheService? get imageCache => _images;

  @override
  String get name => 'reader';

  @override
  List<String> get dependsOn => const ['store', 'shelf', 'sourcefetch'];

  ReaderService get service {
    final service = _service;
    if (service == null) {
      throw StateError('reader 模块尚未 register');
    }
    return service;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    final shelf = ShelfModule.instance;
    final sourceFetch = SourceFetchModule.instance;
    if (store == null || shelf == null) {
      throw StateError('reader 依赖 store/shelf，但依赖模块尚未 register');
    }
    final images = ImageCacheService(homeDir: ctx.homeDir);
    _images = images;
    final reader = ReaderService(
      daos: store.daos,
      shelf: shelf.service,
      sourceFetch: sourceFetch?.service,
      images: images,
      // 设置域在自己的依赖之前注册（见 modules.dart），这里直接取同一个实例；
      // 未装配（CLI 精简模式/单测）时为 null，阅读器用内置默认值。
      settings: SettingsModule.instance?.service,
      homeDir: ctx.homeDir,
    );
    _service = reader;
    instance = this;

    registry.method(
      'Reader.GetChapters',
      (args) async => reader.getChapters(_asInt(_arg(args, 0))),
      params: const ['bookID int'],
      doc: '目录条目；isVolume 是卷标题，不可点',
    );

    registry.method(
      'Reader.GetContent',
      (args) async => reader.getContent(
        _asInt(_arg(args, 0)),
        _asInt(_arg(args, 1)),
        refresh: _arg(args, 2) == true,
      ),
      params: const ['bookID int', 'index int', 'refresh bool?'],
      doc: '章节正文 + 上下章序号；网络书优先读离线缓存，refresh=true 强制联网；'
          '支持本地 txt/epub/umd，PDF 返回阅读提示',
    );

    registry.method(
      'Reader.GetLocalFile',
      (args) async => reader.getLocalFilePath(_asInt(_arg(args, 0))),
      params: const ['bookID int'],
      doc: '本地书源文件绝对路径，供 UI 用平台渲染器打开 PDF；网络书返回空串',
    );

    registry.method(
      'Reader.GetLocalPage',
      (args) async => reader.getLocalPage(
        _asInt(_arg(args, 0)),
        _asInt(_arg(args, 1)),
      ),
      params: const ['bookID int', 'index int'],
      doc: '本地漫画单页：解压到 <home>/cache/comic 并返回 path/mime/pageCount',
    );

    registry.method(
      'Reader.GetProgress',
      (args) async => reader.getProgress(_asInt(_arg(args, 0))),
      params: const ['bookID int'],
      doc: '与 Shelf.GetProgress 同一实现，无记录 chapterIndex=-1',
    );

    registry.method(
      'Reader.SaveProgress',
      (args) async {
        reader.saveProgress(
          _asInt(_arg(args, 0)),
          _asInt(_arg(args, 1)),
          _asText(_arg(args, 2)),
          _asInt(_arg(args, 3)),
          _asDouble(_arg(args, 4)),
        );
        return null;
      },
      params: const [
        'bookID int',
        'chapterIndex int',
        'chapterTitle string',
        'chapterPos int',
        'scrollPercent double',
      ],
      doc: '与 Shelf.SaveProgress 同一实现',
    );

    registry.method(
      'Reader.SyncOutline',
      (args) async {
        reader.syncOutline(_asInt(_arg(args, 0)), _asList(_arg(args, 1)));
        return null;
      },
      params: const ['bookID int', 'items List<ChapterItem>'],
      doc: '前端解析的目录回写，整表替换',
    );
  }

  @override
  void onReady(LegadoContext ctx) {
    // 软件启动即清理过期缓存，不等用户打开阅读页。force 绕过节流，
    // purgeExpiredCache 内部已兜住异常，清理失败不会拖垮启动。
    _service?.purgeExpiredCache(force: true);
  }

  @override
  Future<void> close() async {
    // 先停自动缓存的预取 worker：它还握着数据库句柄，
    // 走完再 close 会在已经关掉的库上查询。
    await _service?.close();
    _images?.close();
    _service = null;
    _images = null;
    if (identical(instance, this)) instance = null;
  }
}

Object? _arg(List<Object?> args, int index) =>
    index < args.length ? args[index] : null;

int _asInt(Object? raw) {
  if (raw == null) return 0;
  if (raw is int) return raw;
  if (raw is num) return raw.isFinite ? raw.toInt() : 0;
  if (raw is String) return int.tryParse(raw.trim()) ?? 0;
  throw LegadoException(ErrorCode.invalid, '需要整数，收到 ${raw.runtimeType}');
}

double _asDouble(Object? raw) {
  if (raw == null) return 0;
  if (raw is num) return raw.toDouble();
  if (raw is String) return double.tryParse(raw.trim()) ?? 0;
  throw LegadoException(ErrorCode.invalid, '需要数字，收到 ${raw.runtimeType}');
}

String _asText(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw;
  if (raw is num || raw is bool) return '$raw';
  throw LegadoException(ErrorCode.invalid, '需要字符串，收到 ${raw.runtimeType}');
}

List<Object?> _asList(Object? raw) {
  if (raw == null) return const [];
  if (raw is List) return raw;
  throw LegadoException(ErrorCode.invalid, '需要数组，收到 ${raw.runtimeType}');
}
