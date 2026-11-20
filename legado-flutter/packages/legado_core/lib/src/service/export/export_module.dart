import '../../kernel/errors.dart';
import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../reader/reader_module.dart';
import '../../store/store.dart' show StoreModule;
import 'export_service.dart';

/// 书架导出域模块。
///
/// 依赖 reader 复用「章节列表 + 正文抓取」那一份实现，导出本身不碰规则引擎；
/// 方法契约见 `docs/方法契约表.md`。
class ExportModule extends CoreModule {
  static ExportModule? instance;

  ExportService? _service;

  @override
  String get name => 'export';

  @override
  List<String> get dependsOn => const ['store', 'reader'];

  ExportService get service {
    final service = _service;
    if (service == null) {
      throw StateError('export 模块尚未 register');
    }
    return service;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    final reader = ReaderModule.instance;
    if (store == null || reader == null) {
      throw StateError('export 依赖 store/reader，但依赖模块尚未 register');
    }
    final export = ExportService(
      daos: store.daos,
      reader: reader.service,
      homeDir: ctx.homeDir,
    );
    _service = export;
    instance = this;

    registry.method(
      'Export.Formats',
      (args) async => export.formatViews(),
      params: const [],
      doc: '导出格式列表；implemented=false 表示接口预留、暂未实现',
    );

    registry.method(
      'Export.Book',
      (args) async => export.exportBook(
        _asInt(_arg(args, 0)),
        _asText(_arg(args, 1)),
        _asText(_arg(args, 2)),
      ),
      params: const [
        'bookID int',
        'format string',
        'outputDir string',
      ],
      doc: '导出单本；format 留空默认 epub，返回 path/format/chapters/bytes',
    );
  }

  @override
  Future<void> close() async {
    _service = null;
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

String _asText(Object? raw) {
  if (raw == null) return '';
  if (raw is String) return raw;
  if (raw is num || raw is bool) return '$raw';
  throw LegadoException(ErrorCode.invalid, '需要字符串，收到 ${raw.runtimeType}');
}
