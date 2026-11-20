import '../../kernel/module.dart';
import '../../kernel/registry.dart';
import '../../store/store.dart';
import '../shelf/shelf_module.dart';
import '../service_args.dart';
import 'bookmark_service.dart';

/// 把 `Bookmark`（5）+ `Record`（4）共 9 个方法挂到注册表。
class BookmarkModule extends CoreModule {
  @override
  String get name => 'bookmark';

  @override
  List<String> get dependsOn => const ['store', 'shelf'];

  @override
  void register(Registry registry, LegadoContext ctx) {
    final store = StoreModule.instance;
    if (store == null) {
      throw StateError('bookmark 依赖 store，但 store 尚未 migrate');
    }
    final progress = _ShelfProgressReader();
    final bookmark = BookmarkService(store.daos, progress: progress);
    final record = RecordService(store.daos, progress: progress);
    registry.method(
      'Bookmark.Add',
      (args) async => (bookmark.add(
        asInt(arg(args, 0)),
        asInt(arg(args, 1)),
        asText(arg(args, 2)),
        asInt(arg(args, 3)),
        asText(arg(args, 4)),
        asText(arg(args, 5)),
      )).toJson(),
      params: const [
        'bookId int',
        'chapterIndex int',
        'chapterTitle string',
        'chapterPos int',
        'content string',
        'note string',
      ],
      doc: 'chapterIndex<0 = 当前位置（读 Shelf 进度）',
    );

    registry.method(
      'Bookmark.List',
      (args) async => bookmark.list(asInt(arg(args, 0)), asInt(arg(args, 1))),
      params: const ['bookId int', 'limit int'],
      doc: 'bookId=0 全部，按 createdAt 倒序',
    );

    registry.method(
      'Bookmark.Remove',
      (args) async {
        bookmark.remove(asInt(arg(args, 0)));
        return null;
      },
      params: const ['id int'],
      doc: '删不到抛 NOT_FOUND',
    );

    registry.method(
      'Bookmark.UpdateNote',
      (args) async {
        bookmark.updateNote(asInt(arg(args, 0)), asText(arg(args, 1)));
        return null;
      },
      params: const ['id int', 'note string'],
    );

    registry.method(
      'Bookmark.Count',
      (args) async => bookmark.count(asInt(arg(args, 0))),
      params: const ['bookId int'],
    );

    registry.method(
      'Record.Append',
      (args) async {
        record.append(
          asInt(arg(args, 0)),
          asText(arg(args, 1)),
          asInt(arg(args, 2)),
          asText(arg(args, 3)),
        );
        return null;
      },
      params: const [
        'bookId int',
        'bookName string',
        'chapterIndex int',
        'chapterTitle string',
      ],
      doc: '同书同日同章只留一条并刷新时间；chapterIndex<0 = 当前位置',
    );

    registry.method(
      'Record.List',
      (args) async => record.list(asInt(arg(args, 0)), asInt(arg(args, 1))),
      params: const ['offset int', 'limit int'],
      doc: '按 readAt 倒序；offset 在 limit 前',
    );

    registry.method(
      'Record.Clear',
      (args) async => record.clear(asInt(arg(args, 0))),
      params: const ['beforeDays int'],
      doc: 'beforeDays=0 全部清空，返回删除条数',
    );

    registry.method(
      'Record.Stats',
      (args) async => record.stats(),
      doc: '{days, books, records}，天数按本地日历日',
    );
  }

}

/// Shelf → ProgressReader 的适配器。
///
/// 延迟读取 `ShelfModule.instance`：注册顺序由拓扑排序保证 shelf 在前，
/// 但测试里也会单独 register bookmark，此时没有 shelf 就降级成 0。
class _ShelfProgressReader implements ProgressReader {
  @override
  int currentChapterIndex(int bookId) {
    final shelf = ShelfModule.instance;
    if (shelf == null) return 0;
    final progress = shelf.service.getProgress(bookId);
    return (progress['chapterIndex'] as num?)?.toInt() ?? 0;
  }
}
