import '../../kernel/errors.dart';
import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import 'shelf_service.dart';

/// 书架域模块：把 [ShelfService] 的 18 个方法挂到注册表。
///
/// 参数一律位置传，并在这一层收敛类型：信封里的数字可能是 `int` 也可能是
/// `double`，bool 偶尔是 `1`/`"true"`。service 只接收已经校好的强类型，
/// 这样「同一份业务被 CLI / App / 测试调用」时行为不会分叉。
class ShelfModule extends CoreModule {
  /// 供 Reader/Bookmark 等后续域复用同一个 service 实例：
  /// 进度只有一套实现，读写入口不同但落点必须一致。
  static ShelfModule? instance;

  ShelfService? _service;

  @override
  String get name => 'shelf';

  @override
  List<String> get dependsOn => const ['store'];

  ShelfService get service {
    final service = _service;
    if (service == null) {
      throw StateError('shelf 模块尚未 register');
    }
    return service;
  }

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) {
      throw StateError('shelf 依赖 store，但 store 尚未 migrate');
    }
    final shelf = ShelfService(daos: store.daos, homeDir: ctx.homeDir);
    _service = shelf;
    instance = this;

    registry.method(
      'Shelf.ListGroups',
      (args) async => shelf.listGroups(),
      doc: '用户自建分组；内置「全部」不下发',
    );

    registry.method(
      'Shelf.ListBooks',
      (args) async => shelf.listBooks(
        _asInt(_arg(args, 0)),
        args.length > 1 ? _asInt(_arg(args, 1)) : -1,
      ),
      params: const ['groupID int', 'sort int?'],
      doc: '在架书籍摘要；groupID=0 为全部，sort 为当前分组的 bookSort（-1 保持默认）',
    );

    registry.method(
      'Shelf.GetBook',
      (args) async => shelf.getBook(_asInt(_arg(args, 0))),
      params: const ['id int'],
      doc: '书籍详情；试读书也返回',
    );

    registry.method(
      'Shelf.PutOnShelf',
      (args) async {
        shelf.putOnShelf(_asInt(_arg(args, 0)));
        return null;
      },
      params: const ['bookID int'],
      doc: '试读转正，只清 notShelf 位',
    );

    registry.method(
      'Shelf.DeleteBook',
      (args) async {
        shelf.deleteBook(_asInt(_arg(args, 0)));
        return null;
      },
      params: const ['id int'],
      doc: '删书并清理章节 / 进度 / 缓存 / 磁盘图片',
    );

    registry.method(
      'Shelf.MoveToGroup',
      (args) async {
        shelf.moveToGroup(_asInt(_arg(args, 0)), _asInt(_arg(args, 1)));
        return null;
      },
      params: const ['bookID int', 'groupID int'],
      doc: '移动书籍到分组；groupID=0 为未分组',
    );

    registry.method(
      'Shelf.SaveProgress',
      (args) async {
        shelf.saveProgress(
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
      doc: '同事务写 books + reading_progress；百分比口径 0~100',
    );

    registry.method(
      'Shelf.GetProgress',
      (args) async => shelf.getProgress(_asInt(_arg(args, 0))),
      params: const ['bookID int'],
      doc: '阅读位置；无记录时 chapterIndex=-1',
    );

    registry.method(
      'Shelf.CreateGroup',
      (args) async => shelf.createGroup(_asText(_arg(args, 0))),
      params: const ['name string'],
      doc: '新建用户分组，返回分组视图',
    );

    registry.method(
      'Shelf.UpdateGroup',
      (args) async {
        shelf.updateGroup(
          _asInt(_arg(args, 0)),
          _asText(_arg(args, 1)),
          _asBool(_arg(args, 2)),
          _asInt(_arg(args, 3)),
          // 后三个是可选追加参数：老调用方只传前四个时保持原行为。
          cover: args.length > 4 ? _asText(_arg(args, 4)) : null,
          bookSort: args.length > 5 ? _asInt(_arg(args, 5)) : null,
          enableRefresh: args.length > 6 ? _asBool(_arg(args, 6)) : null,
        );
        return null;
      },
      params: const [
        'id int',
        'name string',
        'show bool',
        'order int',
        'cover string?',
        'bookSort int?',
        'enableRefresh bool?',
      ],
      doc: '改名 / 显隐 / 排序 / 封面 / 本组排序方式 / 是否参与目录更新；内置分组不可改',
    );

    registry.method(
      'Shelf.SaveBook',
      (args) async => shelf.saveBook(
        _asInt(_arg(args, 0)),
        name: _asText(_arg(args, 1)),
        author: _asText(_arg(args, 2)),
        coverUrl: _asText(_arg(args, 3)),
        intro: _asText(_arg(args, 4)),
        groupId: _asInt(_arg(args, 5)),
      ),
      params: const [
        'bookID int',
        'name string',
        'author string',
        'coverURL string',
        'intro string',
        'groupID int',
      ],
      doc: '编辑书名/作者/封面/简介/分组；groupID<0 不改，封面简介空串=回落书源值',
    );

    registry.method(
      'Shelf.DeleteGroup',
      (args) async {
        shelf.deleteGroup(_asInt(_arg(args, 0)));
        return null;
      },
      params: const ['id int'],
      doc: '删分组，组内书回未分组但不删书',
    );

    // ---- 书架管理（多选批量）----
    registry.method(
      'Shelf.SetCanUpdate',
      (args) async {
        shelf.setCanUpdate(_asIntList(_arg(args, 0)), _asBool(_arg(args, 1)));
        return null;
      },
      params: const ['bookIDs int[]', 'enabled bool'],
      doc: '批量开关「允许更新目录」；书架「更新目录」会跳过 canUpdate=false 的书',
    );

    registry.method(
      'Shelf.MoveToGroups',
      (args) async {
        shelf.moveToGroups(_asIntList(_arg(args, 0)), _asInt(_arg(args, 1)));
        return null;
      },
      params: const ['bookIDs int[]', 'groupID int'],
      doc: '批量移动到分组（覆盖原分组），groupID=0 为未分组',
    );

    registry.method(
      'Shelf.AddToGroups',
      (args) async {
        shelf.addToGroups(_asIntList(_arg(args, 0)), _asInt(_arg(args, 1)));
        return null;
      },
      params: const ['bookIDs int[]', 'groupID int'],
      doc: '批量加入分组（按位或，保留已有分组）',
    );

    registry.method(
      'Shelf.DeleteBooks',
      (args) async {
        shelf.deleteBooks(_asIntList(_arg(args, 0)));
        return null;
      },
      params: const ['bookIDs int[]'],
      doc: '批量删书，逐本清章节/进度/缓存',
    );

    registry.method(
      'Shelf.ExportBookshelf',
      (args) async => shelf.exportBookshelf(_asInt(_arg(args, 0))),
      params: const ['groupID int'],
      doc: '导出书架 JSON（name/author/intro 数组），groupID=0 为全部',
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

List<int> _asIntList(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) {
    throw LegadoException(ErrorCode.invalid, '需要整数数组，收到 ${raw.runtimeType}');
  }
  return [for (final item in raw) _asInt(item)];
}

bool _asBool(Object? raw) {
  if (raw == null) return false;
  if (raw is bool) return raw;
  if (raw is num) return raw != 0;
  if (raw is String) {
    return switch (raw.toLowerCase()) {
      'true' || '1' || 'yes' => true,
      _ => false,
    };
  }
  throw LegadoException(ErrorCode.invalid, '需要布尔值，收到 ${raw.runtimeType}');
}
